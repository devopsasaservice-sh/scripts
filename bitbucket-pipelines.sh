#!/bin/bash

# Step 1: Detect JSON File Changes
function detect_json_changes() {
  apk add --no-cache git curl openssh bash  # Install required packages

  # Detect the single changed JSON file in the current commit
  JSON_FILE=$(git diff --name-only HEAD^ HEAD | grep -E '^iac/.+/.+/.+\.json$' | head -n 1)
  echo "$JSON_FILE"

  # Check if a JSON file was modified
  if [ -z "$JSON_FILE" ]; then
    echo "No JSON file detected. Stopping the pipeline."
    exit 0  # Stop the pipeline if no JSON file was modified
  fi

  # Extract the module path and environment name from the modified file
  MODULE_PATH=$(echo "$JSON_FILE" | sed -E 's|^iac/([^/]+/[^/]+)/.*|\1|')
  ENV=$(basename "$JSON_FILE" .json)
  WORKSPACE_NAME="$(echo ${MODULE_PATH} | tr '/' '-')-${ENV}"

  # Save artifacts for the next steps
  mkdir -p artifacts
  echo "$JSON_FILE" > artifacts/modified_file.txt
  echo "$WORKSPACE_NAME" > artifacts/workspace_name.txt
  echo "$MODULE_PATH" > artifacts/module_path.txt
  cp "$JSON_FILE" artifacts/  # Copy the JSON file as an artifact
}

# Step 2: Create Workspace and Backend in Terraform Cloud
function create_workspace() {
  JSON_FILE=$(cat artifacts/modified_file.txt)
  WORKSPACE_NAME=$(cat artifacts/workspace_name.txt)
  MODULE_PATH=$(cat artifacts/module_path.txt)

  # Create the workspace in Terraform Cloud
  echo "$WORKSPACE_NAME"
  curl -X POST https://app.terraform.io/api/v2/organizations/$TERRAFORM_CLOUD_ORG/workspaces \
    -H 'Content-Type: application/vnd.api+json' \
    -H "Authorization: Bearer $TERRAFORM_CLOUD_API_TOKEN" \
    -d '{
      "data": {
        "attributes": {
          "name": "'"$WORKSPACE_NAME"'",
          "identifier": "'"$WORKSPACE_NAME"'",
          "branch": "main",
          "resource-count": 0,
          "execution-mode": "local"
        },
        "type": "workspaces"
      }
    }' || true  # Continue even if the workspace already exists
}

# Step 3: Run Terraform Plan
function run_terraform_plan() {
  JSON_FILE=$(cat artifacts/modified_file.txt)
  WORKSPACE_NAME=$(cat artifacts/workspace_name.txt)
  MODULE_PATH=$(cat artifacts/module_path.txt)

  # Set Terraform Cloud credentials
  echo 'credentials "app.terraform.io" {
    token = "'"$TERRAFORM_CLOUD_API_TOKEN"'"
  }' > ~/.terraformrc

  # Create backend.tf for the module
  echo "$WORKSPACE_NAME"
  echo '
  terraform {
    cloud {
      organization = "takeachef"
      workspaces {
        name = "'"$WORKSPACE_NAME"'"
      }
    }
  }
  ' > backend.tf

  # Move the JSON file to the module directory, restore backend.tf, initialize and run terraform plan
  mv artifacts/$(basename "$JSON_FILE") iac/${MODULE_PATH}/$(basename "$JSON_FILE")
  cp backend.tf iac/${MODULE_PATH}/
  cd iac/${MODULE_PATH}
  terraform init -upgrade

  # Copy content from the module's main.tf to the current main.tf
  TEMPLATE_DIR=$(echo "$JSON_FILE" | sed -E 's|^iac/([^/]+)|\1/templates|; s|/[^/]+\.json$||')
  MODULE_MAIN_TF=".terraform/modules/${TEMPLATE_DIR}/main.tf"
  CURRENT_MAIN_TF="main.tf"
  echo "Copying content from $MODULE_MAIN_TF to $CURRENT_MAIN_TF"
  sed -i '/^}/d' $CURRENT_MAIN_TF
  awk '/source/ {flag=1; next} flag' "$MODULE_MAIN_TF" >> "$CURRENT_MAIN_TF"

  # Copy the variables.tf and outputs.tf from the module to the current directory
  MODULE_PATH=$(echo "$MODULE_PATH" | sed 's|/|/templates/|')
  MODULE_TF=".terraform/modules/${MODULE_PATH}"
  cp "$MODULE_TF"/variables.tf .
  cp "$MODULE_TF"/outputs.tf .

  apk add --no-cache python3 py3-pip
  pip install awscli --upgrade --user
  ~/.local/bin/aws --version

  export PATH=~/.local/bin:$PATH

  aws --version
  
  # Create terraform.tf for the module
  echo '
  provider "aws" {
    assume_role {
      role_arn     = "${AWS_ROLE_NAME}"
      session_name = "SESSION_NAME"
      external_id  = "EXTERNAL_ID"
    }
  }
  ' > terraform.tf
  terraform plan -var-file="$(basename "$JSON_FILE")"
}

# Step 4: Run Terraform Apply
function run_terraform_apply() {
  JSON_FILE=$(cat artifacts/modified_file.txt)
  WORKSPACE_NAME=$(cat artifacts/workspace_name.txt)
  MODULE_PATH=$(cat artifacts/module_path.txt)

  # Set Terraform Cloud credentials
  echo 'credentials "app.terraform.io" {
    token = "'"$TERRAFORM_CLOUD_API_TOKEN"'"
  }' > ~/.terraformrc

  # Create backend.tf for the module
  echo "$WORKSPACE_NAME"
  echo '
  terraform {
    cloud {
      organization = "takeachef"
      workspaces {
        name = "'"$WORKSPACE_NAME"'"
      }
    }
  }
  ' > backend.tf

  # Restore backend.tf, initialize and run terraform apply
  cp backend.tf iac/${MODULE_PATH}/
  cd iac/${MODULE_PATH}
  terraform init -upgrade
  terraform apply --auto-approve -var-file="$(basename "$JSON_FILE")"
}

# Main function to call based on the argument
case "$1" in
  "detect_changes") detect_json_changes ;;
  "create_workspace") create_workspace ;;
  "terraform_plan") run_terraform_plan ;;
  "terraform_apply") run_terraform_apply ;;
  *) echo "Invalid argument. Use 'detect_changes', 'create_workspace', 'terraform_plan', or 'terraform_apply'." ;;
esac
