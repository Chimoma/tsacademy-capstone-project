output "vpc_id" {
  value = module.vpc.vpc_id
}

output "name_servers" {
  value       = module.dns.name_servers
  description = "Add these to your domain registrar"
}

output "kops_access_key_id" {
  value = module.iam.kops_access_key_id
}

output "kops_secret_access_key" {
  value     = module.iam.kops_secret_access_key
  sensitive = true
}