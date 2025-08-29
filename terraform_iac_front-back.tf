############################################
# main.tf — Blueprint ALB+ASG+Redis (eu-west-3)
############################################
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.50" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

########################
# Variables
########################
variable "project_name" { type = string, default = "sre-blueprint" }
variable "region"       { type = string, default = "eu-west-3" } # Paris
variable "your_ip_cidr" {
  description = "IP autorisée en SSH (restreins en prod)"
  type        = string
  default     = "0.0.0.0/0"
}

# Réseau
variable "vpc_cidr" { type = string, default = "10.0.0.0/16" }
# Choisis des /24 disjoints; 2 publics + 2 privés
variable "public_subnet_cidrs"  { type = list(string), default = ["10.0.1.0/24","10.0.2.0/24"] }
variable "private_subnet_cidrs" { type = list(string), default = ["10.0.11.0/24","10.0.12.0/24"] }

# ALB TLS: passe l'ARN d'un certificat ACM valide (même région que l'ALB)
variable "acm_certificate_arn" {
  type        = string
  description = "ARN du certificat ACM (pour HTTPS sur l'ALB)."
}

# (Optionnel) DNS: si tu veux un nom (A/ALIAS) pour l'ALB
variable "domain_name"     { type = string, default = "" } # ex: app.example.com
variable "hosted_zone_id"  { type = string, default = "" } # zone publique Route53 contenant domain_name

# ASG
variable "instance_type" { type = string, default = "t3.micro" }
variable "asg_min"       { type = number, default = 2 }
variable "asg_max"       { type = number, default = 5 }
variable "asg_target_cpu"{ type = number, default = 40 }  # % cible

# Redis (ElastiCache)
variable "redis_node_type" { type = string, default = "cache.t4g.small" }
variable "redis_replicas"  { type = number, default = 1 }       # 1 réplica = multi-AZ
variable "redis_engine_ver"{ type = string, default = "7.0" }
variable "redis_transit_encryption" { type = bool, default = true }
variable "redis_auth_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Token AUTH Redis (obligatoire si transit_encryption = true sauf ACLs avancées)."
}

provider "aws" { region = var.region }

data "aws_availability_zones" "azs" {
  state = "available"
}

########################
# Réseau: VPC + Subnets + IGW + NAT/GW + Routes
########################
resource "aws_vpc" "vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "${var.project_name}-vpc" }
}

# 2 subnets publics (AZ 0/1)
resource "aws_subnet" "public" {
  for_each = { for idx, cidr in var.public_subnet_cidrs : idx => cidr }
  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = each.value
  availability_zone       = data.aws_availability_zones.azs.names[tonumber(each.key)]
  map_public_ip_on_launch = true
  tags = { Name = "${var.project_name}-public-${each.key}" }
}

# 2 subnets privés (AZ 0/1)
resource "aws_subnet" "private" {
  for_each = { for idx, cidr in var.private_subnet_cidrs : idx => cidr }
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = each.value
  availability_zone = data.aws_availability_zones.azs.names[tonumber(each.key)]
  tags = { Name = "${var.project_name}-private-${each.key}" }
}

# IGW pour l'accès Internet des subnets publics
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
  tags = { Name = "${var.project_name}-igw" }
}

# EIP + NAT GW par AZ (bonne HA, routes locales)
resource "aws_eip" "nat" {
  for_each = aws_subnet.public
  domain   = "vpc"
  tags = { Name = "${var.project_name}-eip-nat-${each.key}" }
}

resource "aws_nat_gateway" "nat" {
  for_each      = aws_subnet.public
  subnet_id     = each.value.id
  allocation_id = aws_eip.nat[each.key].id
  tags = { Name = "${var.project_name}-nat-${each.key}" }
  depends_on = [aws_internet_gateway.igw]
}

# Route tables: 1 publique (commune) + 1 privée par AZ (vers son NAT)
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.vpc.id
  tags   = { Name = "${var.project_name}-rt-public" }
}
resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}
resource "aws_route_table_association" "assoc_public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Route tables: 1 privée par AZ (vers son NAT)
resource "aws_route_table" "private" {
  for_each = aws_subnet.private
  vpc_id   = aws_vpc.vpc.id
  tags     = { Name = "${var.project_name}-rt-private-${each.key}" }
}
resource "aws_route" "private_default" {
  for_each                = aws_route_table.private
  route_table_id          = each.value.id
  destination_cidr_block  = "0.0.0.0/0"
  nat_gateway_id          = aws_nat_gateway.nat[each.key].id
}
resource "aws_route_table_association" "assoc_private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

########################
# Security Groups
########################
# ALB: 80/443 depuis Internet
resource "aws_security_group" "alb_sg" {
  name   = "${var.project_name}-alb-sg"
  vpc_id = aws_vpc.vpc.id

  ingress { from_port = 80,  to_port = 80,  protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 443, to_port = 443, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] }
  egress  { from_port = 0,   to_port = 0,   protocol = "-1",  cidr_blocks = ["0.0.0.0/0"] }

  tags = { Name = "${var.project_name}-alb-sg" }
}

# App: HTTP seulement depuis l'ALB + SSH depuis ton IP (optionnel)
resource "aws_security_group" "app_sg" {
  name   = "${var.project_name}-app-sg"
  vpc_id = aws_vpc.vpc.id

  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }
  ingress {
    description = "SSH (admin)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.your_ip_cidr]
  }
  egress { from_port = 0, to_port = 0, protocol = "-1", cidr_blocks = ["0.0.0.0/0"] }

  tags = { Name = "${var.project_name}-app-sg" }
}

# Redis: 6379 seulement depuis app_sg
resource "aws_security_group" "redis_sg" {
  name   = "${var.project_name}-redis-sg"
  vpc_id = aws_vpc.vpc.id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.app_sg.id]
  }
  egress { from_port = 0, to_port = 0, protocol = "-1", cidr_blocks = ["0.0.0.0/0"] }

  tags = { Name = "${var.project_name}-redis-sg" }
}

########################
# ALB + Target Group + Listeners (HTTPS)
########################
resource "aws_lb" "alb" {
  name               = "${var.project_name}-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [for s in aws_subnet.public : s.id]
  idle_timeout       = 60
  enable_deletion_protection = false
  tags = { Name = "${var.project_name}-alb" }
}

resource "aws_lb_target_group" "tg" {
  name        = "${var.project_name}-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.vpc.id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = "/"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "${var.project_name}-tg" }
}

# HTTP -> redirection HTTPS
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      status_code = "HTTP_301"
      port        = "443"
      protocol    = "HTTPS"
    }
  }
}

# HTTPS (certificat ACM fourni)
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

########################
# AMI Ubuntu + Launch Template + ASG
########################
data "aws_ami" "ubuntu" {
  owners      = ["099720109477"] # Canonical
  most_recent = true
  filter { name = "name", values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"] }
}

locals {
  user_data = <<-BASH
    #!/usr/bin/env bash
    set -e
    apt-get update -y
    apt-get install -y nginx
    echo "<h1>${HOSTNAME} - ${var.project_name}</h1>" > /var/www/html/index.html
    systemctl enable nginx && systemctl restart nginx
  BASH
}

resource "aws_launch_template" "lt" {
  name_prefix   = "${var.project_name}-lt-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  user_data     = base64encode(local.user_data)

  monitoring { enabled = true } # détaillé (1min) utile si tu repasses à des alarms manuelles

  network_interfaces {
    security_groups             = [aws_security_group.app_sg.id]
    associate_public_ip_address = false
  }

  tag_specifications {
    resource_type = "instance"
    tags = { Name = "${var.project_name}-app" }
  }
}

resource "aws_autoscaling_group" "asg" {
  name                      = "${var.project_name}-asg"
  desired_capacity          = var.asg_min
  min_size                  = var.asg_min
  max_size                  = var.asg_max
  vpc_zone_identifier       = [for s in aws_subnet.private : s.id]
  health_check_type         = "ELB"
  health_check_grace_period = 60

  launch_template {
    id      = aws_launch_template.lt.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.tg.arn]

  tag {
    key                 = "Name"
    value               = "${var.project_name}-app"
    propagate_at_launch = true
  }

  lifecycle { create_before_destroy = true }
}

# Target Tracking CPU (AWS gère ses alarmes)
resource "aws_autoscaling_policy" "tt_cpu" {
  name                   = "${var.project_name}-cpu-tt"
  policy_type            = "TargetTrackingScaling"
  autoscaling_group_name = aws_autoscaling_group.asg.name

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value     = var.asg_target_cpu
    disable_scale_in = false
  }
}

########################
# ElastiCache Redis (sessions)
########################
resource "aws_elasticache_subnet_group" "redis" {
  name       = "${var.project_name}-redis-subnets"
  subnet_ids = [for s in aws_subnet.private : s.id]
}

# Pour Redis 7 + chiffrement: token si transit_encryption=true (ou config ACLs avancées)
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id          = "${var.project_name}-redis"
  description                   = "Sessions/cache"
  engine                        = "redis"
  engine_version                = var.redis_engine_ver
  node_type                     = var.redis_node_type
  parameter_group_name          = "default.redis7"
  port                          = 6379

  subnet_group_name             = aws_elasticache_subnet_group.redis.name
  security_group_ids            = [aws_security_group.redis_sg.id]

  automatic_failover_enabled    = true
  multi_az_enabled              = true
  num_cache_clusters            = var.redis_replicas + 1  # primary + replicas

  at_rest_encryption_enabled    = true
  transit_encryption_enabled    = var.redis_transit_encryption
  auth_token                    = var.redis_transit_encryption && length(var.redis_auth_token) > 0 ? var.redis_auth_token : null

  # Si tu utilises auth_token, pense à le garder en secret et à le propager à l'app.
  lifecycle { ignore_changes = [auth_token] } # évite de recréer si tu changes le token manuellement

  tags = { Name = "${var.project_name}-redis" }
}

########################
# (Optionnel) DNS record pour l'ALB
########################
resource "aws_route53_record" "alb_alias" {
  count   = length(var.domain_name) > 0 && length(var.hosted_zone_id) > 0 ? 1 : 0
  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"
  alias {
    name                   = aws_lb.alb.dns_name
    zone_id                = aws_lb.alb.zone_id
    evaluate_target_health = false
  }
}

########################
# Outputs utiles
########################
output "alb_dns_name"     { value = aws_lb.alb.dns_name }
output "alb_https_url"    { value = length(var.domain_name) > 0 ? "https://${var.domain_name}" : "https://${aws_lb.alb.dns_name}" }
output "asg_name"         { value = aws_autoscaling_group.asg.name }
output "redis_primary"    { value = aws_elasticache_replication_group.redis.primary_endpoint_address }
output "redis_reader"     { value = aws_elasticache_replication_group.redis.reader_endpoint_address }
