resource "aws_route53_zone" "main" {
  name = var.domain_name

  tags = {
    Name    = "${var.project_name}-hosted-zone"
    Project = var.project_name
  }
}