variable "vpc_cidr" {
  description = "The IP range for the entire VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "project_name" {
  description = "Used for tagging resources"
  type        = string
}

variable "availability_zones" {
  description = "List of 3 AZs to spread resources across"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}