############################################
# networking.tf
# VPC, IGW, NAT Gateway, 3x subnet tiers, 3x route tables
# Reused for test/prod via var.environment + var.vpc_cidr
############################################

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  az_count = 2
  azs      = slice(data.aws_availability_zones.available.names, 0, local.az_count)

  # /24s carved out of var.vpc_cidr (expected /16):
  #   public:  10.0.1.0/24,  10.0.2.0/24
  #   app:     10.0.10.0/24, 10.0.11.0/24
  #   data:    10.0.20.0/24, 10.0.21.0/24
  public_subnet_cidrs = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 1)]
  app_subnet_cidrs    = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 10)]
  data_subnet_cidrs   = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 20)]

  common_tags = {
    Project     = "amster2k2x"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

############################################
# VPC + IGW
############################################

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "amster2k2x-${var.environment}-vpc"
  })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "amster2k2x-${var.environment}-igw"
  })
}

############################################
# Public Subnets — ALB + NAT Gateway
############################################

resource "aws_subnet" "public" {
  count                   = local.az_count
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "amster2k2x-${var.environment}-public-${local.azs[count.index]}"
    Tier = "public"
  })
}

############################################
# Private App Subnets — ECS Fargate tasks
############################################

resource "aws_subnet" "private_app" {
  count             = local.az_count
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.app_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.common_tags, {
    Name = "amster2k2x-${var.environment}-app-${local.azs[count.index]}"
    Tier = "private-app"
  })
}

############################################
# Isolated Private Data Subnets — RDS + ElastiCache
# No IGW/NAT route — local VPC traffic only.
############################################

resource "aws_subnet" "data" {
  count             = local.az_count
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.data_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.common_tags, {
    Name = "amster2k2x-${var.environment}-data-${local.azs[count.index]}"
    Tier = "isolated-data"
  })
}

############################################
# NAT Gateway — single, in public[0]
# Destroyed with build/ on teardown per cost model (~$32/mo fixed)
############################################

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "amster2k2x-${var.environment}-nat-eip"
  })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = merge(local.common_tags, {
    Name = "amster2k2x-${var.environment}-nat"
  })

  depends_on = [aws_internet_gateway.main]
}

############################################
# Route Tables
############################################

# Public: 0.0.0.0/0 → IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "amster2k2x-${var.environment}-rt-public"
  })
}

resource "aws_route_table_association" "public" {
  count          = local.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# App: 0.0.0.0/0 → NAT Gateway (outbound-only egress for GHCR pulls, Telegram API)
resource "aws_route_table" "app" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "amster2k2x-${var.environment}-rt-app"
  })
}

resource "aws_route_table_association" "app" {
  count          = local.az_count
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app.id
}

# Data: no routes added — implicit local VPC route only.
# Enforces zero internet egress from RDS/ElastiCache subnets.
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "amster2k2x-${var.environment}-rt-data"
  })
}

resource "aws_route_table_association" "data" {
  count          = local.az_count
  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data.id
}