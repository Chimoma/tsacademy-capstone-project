terraform {
  backend "s3" {
    bucket         = "taskapp-terraform-state-cynthia"
    key            = "taskapp/terraform.tfstate" 
    region         = "us-east-1"
    dynamodb_table = "taskapp-terraform-locks"
    encrypt        = true
  }
}