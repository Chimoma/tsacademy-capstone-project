variable "project_name" {
  default = "taskapp"
}

variable "domain_name" {
  description = "Your registered domain"
  type        = string
}

variable "aws_region" {
  default = "us-east-1"
}