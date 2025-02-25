#!/bin/bash

pem_gen() {
  local username=$1
  local email=$2
 
  cat << EOF > $username-config.csr
[req]
distinguished_name = dn
req_extensions = v3_req
prompt = no
 
[dn]
C = KR
L = Daejeon
O = Somaz, Inc.
OU = Dev
CN = $username
 
[v3_req]
subjectAltName = @alt_names
 
[alt_names]
email = $email
EOF
 
  openssl req \
    -new \
    -newkey rsa:2048 \
    -sha256 \
    -nodes \
    -config $username-config.csr \
    -keyout $username-key.pem \
    -out $username.csr
}
 
generate_config() {
  context=$1
  username=$2
  email=$3
  expiration_days=$4
  role=$5
  namespace=$6
 
  # 고유한 CSR 이름 생성
  timestamp=$(date +%s)
  csr_name="csr-${username}-${timestamp}"
 
  pem_gen $username $email
  
  # CSR 인코딩
  if command -v gbase64 &> /dev/null; then
    # macOS에서 gbase64 사용 (brew install coreutils로 설치)
    csr_encoded=$(cat $username.csr | gbase64 -w 0)
  else
    # Linux에서 base64 사용
    csr_encoded=$(cat $username.csr | base64 -w 0)
  fi
 
  # 만료 기간 설정
  if [ "$expiration_days" == "unlimited" ] || [ "$expiration_days" == "infinity" ]; then
    # 최대 허용 기간 (약 63년)
    expiration_seconds=2000000000
    echo "Setting certificate expiration to maximum allowed (approximately 63 years)"
  else
    expiration_seconds=$((expiration_days * 24 * 3600))
    echo "Setting certificate expiration to ${expiration_days} days (${expiration_seconds} seconds)"
  fi
 
  # CSR 생성
  cat <<EOF | kubectl --context=${context} create -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${csr_name}
spec:
  expirationSeconds: ${expiration_seconds}
  signerName: kubernetes.io/kube-apiserver-client
  groups:
  - system:authenticated
  request: ${csr_encoded}
  usages:
  - digital signature
  - key encipherment
  - client auth
EOF
 
  # CSR 승인
  kubectl --context=${context} certificate approve ${csr_name}
  
  # 인증서 가져오기 (여러 번 시도)
  max_attempts=5
  attempt=1
  cert_data=""
  
  while [ $attempt -le $max_attempts ]; do
    echo "Attempting to get certificate data (attempt $attempt/$max_attempts)..."
    cert_data=$(kubectl --context=${context} get csr ${csr_name} -o jsonpath='{.status.certificate}')
    
    if [ -n "$cert_data" ]; then
      echo "Successfully retrieved certificate data"
      break
    fi
    
    echo "Waiting for certificate to be issued..."
    sleep 2
    ((attempt++))
  done
  
  if [ -z "$cert_data" ]; then
    echo "Error: Failed to get certificate data after $max_attempts attempts"
    kubectl --context=${context} get csr ${csr_name} -o yaml
    exit 1
  fi
  
  # 인증서 저장
  echo "$cert_data" | base64 --decode > $username-${context}.crt
  kubectl --context=${context} delete csr ${csr_name}
 
  # 클러스터 정보 가져오기
  clustername=$(kubectl --context=${context} config view -o jsonpath="{.contexts[?(@.name==\"${context}\")].context.cluster}")
  certificate_authority_data=$(kubectl --context=${context} config view --raw -o jsonpath="{.clusters[?(@.name==\"${clustername}\")].cluster.certificate-authority-data}")
  server=$(kubectl --context=${context} config view -o jsonpath="{.clusters[?(@.name==\"${clustername}\")].cluster.server}")
  
  # kubeconfig 디렉토리 생성
  mkdir -p ./output
  
  # 인증서 데이터 인코딩
  if command -v gbase64 &> /dev/null; then
    # macOS에서 gbase64 사용
    cert_data_encoded=$(cat $username-${context}.crt | gbase64 -w 0)
    key_data_encoded=$(cat $username-key.pem | gbase64 -w 0)
  else
    # Linux에서 base64 사용
    cert_data_encoded=$(cat $username-${context}.crt | base64 -w 0)
    key_data_encoded=$(cat $username-key.pem | base64 -w 0)
  fi
  
  # kubeconfig 파일 생성
  kubectl config --kubeconfig=./output/${username}.config set-cluster ${clustername} --server=${server}
  kubectl config --kubeconfig=./output/${username}.config set clusters.${clustername}.certificate-authority-data ${certificate_authority_data}
 
  kubectl config --kubeconfig=./output/${username}.config set-credentials ${context}-${username}
  kubectl config --kubeconfig=./output/${username}.config set users.${context}-${username}.client-certificate-data ${cert_data_encoded}
  kubectl config --kubeconfig=./output/${username}.config set users.${context}-${username}.client-key-data ${key_data_encoded}
  kubectl config --kubeconfig=./output/${username}.config set-context ${context} --user=${context}-${username} --cluster=${clustername}
  kubectl config --kubeconfig=./output/${username}.config use-context ${context}
  
  echo "Generated kubeconfig for user '${username}' in ./output/${username}.config"
  
  # 권한 부여
  if [ -n "$role" ]; then
    create_role_binding $context $username $role $namespace
  fi
 
  # 테스트 명령 실행
  echo "Testing kubeconfig..."
  kubectl --kubeconfig=./output/${username}.config get nodes || echo "Warning: Unable to access nodes with the generated kubeconfig"
 
  # 임시 파일 정리
  rm -f ./*.csr ./*.pem ./*.crt
}

create_role_binding() {
  local context=$1
  local username=$2
  local role=$3
  local namespace=$4

  # 네임스페이스가 지정되지 않은 경우 기본값 설정
  if [ -z "$namespace" ]; then
    namespace="default"
  fi

  # 역할이 지정되지 않은 경우 기본값 설정
  if [ -z "$role" ]; then
    role="view"  # 기본 권한은 view로 설정
  fi

  # RoleBinding 이름 생성
  binding_name="${username}-${role}-binding"

  # 클러스터 역할인지 확인 (namespace가 "all"인 경우)
  if [ "$namespace" == "all" ]; then
    # 이미 ClusterRoleBinding이 존재하는지 확인
    if kubectl --context=${context} get clusterrolebinding ${binding_name} &> /dev/null; then
      echo "ClusterRoleBinding '${binding_name}' already exists. Updating..."
      # 기존 ClusterRoleBinding 업데이트
      cat <<EOF | kubectl --context=${context} apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${binding_name}
subjects:
- kind: User
  name: ${username}
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: ${role}
  apiGroup: rbac.authorization.k8s.io
EOF
      echo "Updated ClusterRoleBinding '${binding_name}' for user '${username}' with ClusterRole '${role}'"
    else
      # 새 ClusterRoleBinding 생성
      cat <<EOF | kubectl --context=${context} create -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${binding_name}
subjects:
- kind: User
  name: ${username}
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: ${role}
  apiGroup: rbac.authorization.k8s.io
EOF
      echo "Created ClusterRoleBinding '${binding_name}' for user '${username}' with ClusterRole '${role}'"
    fi
  else
    # 네임스페이스가 존재하는지 확인
    if ! kubectl --context=${context} get namespace ${namespace} &> /dev/null; then
      echo "Creating namespace '${namespace}'..."
      kubectl --context=${context} create namespace ${namespace}
    fi

    # 이미 RoleBinding이 존재하는지 확인
    if kubectl --context=${context} get rolebinding ${binding_name} -n ${namespace} &> /dev/null; then
      echo "RoleBinding '${binding_name}' already exists in namespace '${namespace}'. Updating..."
      # 기존 RoleBinding 업데이트
      cat <<EOF | kubectl --context=${context} apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${binding_name}
  namespace: ${namespace}
subjects:
- kind: User
  name: ${username}
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: ${role}
  apiGroup: rbac.authorization.k8s.io
EOF
      echo "Updated RoleBinding '${binding_name}' for user '${username}' with Role '${role}' in namespace '${namespace}'"
    else
      # 새 RoleBinding 생성
      cat <<EOF | kubectl --context=${context} create -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${binding_name}
  namespace: ${namespace}
subjects:
- kind: User
  name: ${username}
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: ${role}
  apiGroup: rbac.authorization.k8s.io
EOF
      echo "Created RoleBinding '${binding_name}' for user '${username}' with Role '${role}' in namespace '${namespace}'"
    fi
  fi
}
 
###
 
mkdir -p ./output
 
while read line; do
  # 빈 줄이나 주석 줄 건너뛰기
  [[ -z "$line" || "$line" =~ ^#.*$ ]] && continue
  
  # 공백으로 구분된 필드 읽기
  read -r username email context expiration_days role namespace <<< "$line"
  
  # 필수 필드 확인
  if [ -z "$username" ] || [ -z "$email" ] || [ -z "$context" ]; then
    echo "Error: Missing required fields for line: $line"
    echo "Required format: username email context [expiration_days] [role] [namespace]"
    continue
  fi
  
  # 만료일이 지정되지 않은 경우 기본값 설정
  if [ -z "$expiration_days" ]; then
    expiration_days=365  # 기본 1년
  fi
  
  echo "Processing: $username $email $context $expiration_days $role $namespace"
  generate_config $context $username $email $expiration_days $role $namespace
  echo "----------------------------------------"
 
done < ./list