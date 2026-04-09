output "zone_id" {
  value       = aws_route53_zone.main.zone_id
  description = "Used by Kops when creating the cluster"
}

output "name_servers" {
  value       = aws_route53_zone.main.name_servers
  description = "Copy these 4 NS records to your domain registrar"
}