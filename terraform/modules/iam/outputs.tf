output "kops_access_key_id"     { value = aws_iam_access_key.kops.id }
output "kops_secret_access_key" {
  value     = aws_iam_access_key.kops.secret
  sensitive = true  # won't print in terminal output
}
output "node_instance_profile_name" { value = aws_iam_instance_profile.node.name }