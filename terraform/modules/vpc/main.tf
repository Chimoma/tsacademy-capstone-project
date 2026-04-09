# ── VPC ──────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true   # needed for internal AWS DNS
  enable_dns_hostnames = true   # needed for Kops/Kubernetes

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# ── INTERNET GATEWAY (public traffic in/out) ─────────────────────
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

# ── PUBLIC SUBNETS (one per AZ) ──────────────────────────────────
resource "aws_subnet" "public" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet("10.0.0.0/16", 8, count.index + 1)
  # Results in: 10.0.1.0/24, 10.0.2.0/24, 10.0.3.0/24
  availability_zone = var.availability_zones[count.index]

  map_public_ip_on_launch = true  # instances here get public IPs

  tags = {
    Name                     = "${var.project_name}-public-${count.index + 1}"
    "kubernetes.io/role/elb" = "1"  # tells Kops to use these for load balancers
  }
}

# ── PRIVATE SUBNETS (one per AZ) ─────────────────────────────────
resource "aws_subnet" "private" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet("10.0.0.0/16", 8, count.index + 10)
  # Results in: 10.0.10.0/24, 10.0.11.0/24, 10.0.12.0/24
  availability_zone = var.availability_zones[count.index]

  map_public_ip_on_launch = false  # NO public IPs — nodes stay private

  tags = {
    Name                              = "${var.project_name}-private-${count.index + 1}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# ── ELASTIC IPs for NAT Gateways ─────────────────────────────────
# Each NAT Gateway needs a static public IP
resource "aws_eip" "nat" {
  count  = 3
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat-eip-${count.index + 1}"
  }
}

# ── NAT GATEWAYS (one per public subnet) ─────────────────────────
# Allows private subnet instances to reach the internet (e.g., pull Docker images)
# but the internet cannot reach them directly
resource "aws_nat_gateway" "nat" {
  count         = 3
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "${var.project_name}-nat-${count.index + 1}"
  }

  depends_on = [aws_internet_gateway.igw]
}

# ── ROUTE TABLE: Public ───────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = { Name = "${var.project_name}-rt-public" }
}

resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── ROUTE TABLES: Private (one per AZ, each pointing to its own NAT) ──
resource "aws_route_table" "private" {
  count  = 3
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat[count.index].id
  }

  tags = { Name = "${var.project_name}-rt-private-${count.index + 1}" }
}

resource "aws_route_table_association" "private" {
  count          = 3
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}