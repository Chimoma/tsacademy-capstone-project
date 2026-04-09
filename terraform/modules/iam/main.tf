# ── KOPS USER (for cluster creation) ────────────────────────────
# Kops needs specific AWS permissions to create/manage your K8s cluster
resource "aws_iam_user" "kops" {
  name = "${var.project_name}-kops-user"
  tags = { Name = "${var.project_name}-kops-user" }
}

resource "aws_iam_access_key" "kops" {
  user = aws_iam_user.kops.name
}

# Attach the minimum required policies for Kops
resource "aws_iam_user_policy_attachment" "kops_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEC2FullAccess",
    "arn:aws:iam::aws:policy/AmazonRoute53FullAccess",
    "arn:aws:iam::aws:policy/AmazonS3FullAccess",
    "arn:aws:iam::aws:policy/IAMFullAccess",
    "arn:aws:iam::aws:policy/AmazonVPCFullAccess",
    "arn:aws:iam::aws:policy/AmazonSQSFullAccess",
    "arn:aws:iam::aws:policy/AmazonEventBridgeFullAccess"
  ])
  user       = aws_iam_user.kops.name
  policy_arn = each.value
}

# ── EC2 INSTANCE PROFILE (for master + worker nodes) ─────────────
# Instead of hardcoding credentials on nodes, they assume this role automatically
resource "aws_iam_role" "node" {
  name = "${var.project_name}-node-role"

  # "assume_role_policy" = who is allowed to use this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.project_name}-node-profile"
  role = aws_iam_role.node.name
}

# Attach policies nodes need (e.g., read S3 for etcd backups)
resource "aws_iam_role_policy_attachment" "node_s3" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}