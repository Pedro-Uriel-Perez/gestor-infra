// Pipeline de INFRAESTRUCTURA (job gestor-infra):
// valida el código IaC → escaneo de seguridad del IaC → terraform plan → terraform apply (Render)
// → Ansible: base de datos, verificación de servicios y stack de monitoreo
pipeline {
    agent any

    parameters {
        booleanParam(name: 'APLICAR', defaultValue: true,
                     description: 'Aplicar los cambios en Render (terraform apply). Si se desmarca, solo se genera el plan.')
    }

    environment {
        RENDER_API_KEY = credentials('render-api-key')
        GRAFANA_ADMIN_PASSWORD = credentials('grafana-admin')
        TF_IN_AUTOMATION = 'true'
        // El estado de Terraform vive en el volumen de Jenkins, fuera del repositorio
        TF_ESTADO = '/var/jenkins_home/terraform/gestor-infra.tfstate'
        // Caché de Trivy propia de cada job (incidencia INC-09: dos pipelines actualizando la
        // misma base de Trivy al mismo tiempo provocan SIGSEGV)
        TRIVY_CACHE_DIR = "/var/jenkins_home/trivy-cache/${env.JOB_NAME}"
        ANSIBLE_FORCE_COLOR = 'false'
    }

    options {
        timestamps()
        disableConcurrentBuilds()
        timeout(time: 60, unit: 'MINUTES')
    }

    stages {
        stage('Versiones') {
            steps {
                sh '''
                    terraform version
                    ansible --version | head -1
                    ansible-lint --version | head -1
                    trivy --version | head -1
                    docker version --format 'Docker cliente {{.Client.Version}} / servidor {{.Server.Version}}'
                    mkdir -p reportes "$(dirname "$TF_ESTADO")"
                '''
            }
        }
        stage('Validar IaC') {
            steps {
                dir('terraform') {
                    sh 'terraform fmt -check -recursive -diff'
                    sh 'terraform init -input=false -no-color -backend-config="path=$TF_ESTADO"'
                    sh 'terraform validate -no-color'
                }
                // Buenas prácticas de los playbooks (idempotencia, nombres, módulos con FQCN, etc.)
                // (bash con pipefail: si el comando falla, el tee no oculta el error)
                sh '''#!/bin/bash
                    set -eo pipefail
                    cd ansible && ansible-lint --nocolor . 2>&1 | tee ../reportes/ansible-lint.txt
                '''
            }
        }
        stage('Escaneo de seguridad del IaC (Trivy)') {
            steps {
                // Terraform, Dockerfiles del monitoreo y docker-compose; falla con hallazgos HIGH/CRITICAL
                sh '''
                    trivy config --format table --output reportes/trivy-iac.txt .
                    cat reportes/trivy-iac.txt
                    trivy config --severity HIGH,CRITICAL --exit-code 1 --quiet .
                '''
            }
        }
        stage('Plan') {
            steps {
                dir('terraform') {
                    sh '''#!/bin/bash
                        set -eo pipefail
                        terraform plan -input=false -no-color -out=plan.tfplan | tee ../reportes/terraform-plan.txt
                    '''
                }
            }
        }
        stage('Aprovisionar en Render (apply)') {
            when { expression { params.APLICAR } }
            steps {
                dir('terraform') {
                    sh '''#!/bin/bash
                        set -eo pipefail
                        terraform apply -input=false -no-color plan.tfplan | tee ../reportes/terraform-apply.txt
                        # Las salidas (con secretos) se pasan a Ansible en un archivo que se borra al final
                        terraform output -json > ../ansible/salidas_terraform.json
                        terraform output -no-color | tee ../reportes/terraform-salidas.txt
                    '''
                }
            }
        }
        stage('Configurar base de datos (Ansible)') {
            when { expression { params.APLICAR } }
            steps {
                dir('ansible') {
                    sh 'ansible-playbook basedatos.yml'
                }
            }
        }
        stage('Verificar servicios (Ansible)') {
            when { expression { params.APLICAR } }
            steps {
                dir('ansible') {
                    sh 'ansible-playbook verificacion.yml'
                }
            }
        }
        stage('Desplegar monitoreo (Ansible)') {
            when { expression { params.APLICAR } }
            steps {
                dir('ansible') {
                    sh 'ansible-playbook monitoreo.yml'
                }
            }
        }
    }

    post {
        always {
            sh 'rm -f ansible/salidas_terraform.json terraform/plan.tfplan'
            archiveArtifacts artifacts: 'reportes/**', allowEmptyArchive: true
        }
    }
}
