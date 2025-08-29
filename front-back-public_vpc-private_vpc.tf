# Faire un projet classique d'une application web Front + backend sur AWS avec Terraform avec une base de données mysql en stateful
# Sans utiliser de loadbalancer
terraform { #spécifies providers and versions
  required_providers { 
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" { # Configues authentification & region
  region = "us-west-1"
}


########################
# Data
########################

data "aws_availability_zones" "available" {}

data "aws_ami" "al2" {
    most_recent = true
    owners      = ["amazon"] 
    filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
    }
}

########################
# Variables
########################

# Ta propre IP pour limiter le SSH (remplace x.x.x.x/32)
variable "my_ip" {
    type    = string
    default = "x.x.x.x/32"
}

# (Optionnel) ta clé SSH existante
variable "key_name" {
    type    = string
    default = null
}

########################
# Réseau: VPC + Subnets
########################
resource "aws_vpc" "main" {
    cidr_block = "10.0.0.0/16" # (Classless Inter-Domain Routing) 
    enable_dns_support   = true # Permet la résolution DNS dans le VPC
    enable_dns_hostnames = true # Permet d'attribuer des noms DNS aux instances
    
    tags = { Name = "main_vpc" } # Tags pour identifier la VPC
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
    vpc_id = aws_vpc.main.id

    tags = {
        Name = "my-igw"
    }
}


# EIP pour NAT
resource "aws_eip" "nat_eip" {
  domain = "vpc"
  tags = { Name = "nat-eip" }
}

# NAT
resource "aws_nat_gateway" "nat" {
    allocation_id = aws_eip.nat.id
    subnet_id     = aws_subnet.public.id
    depends_on    = [aws_internet_gateway.igw]
    tags = {
        Name = "my-nat-gateway"
    }
}

# =====
# Subnet public
resource "aws_subnet" "public" {
    vpc_id                  = aws_vpc.main.id
    cidr_block              = "10.0.1.0/24"
    availability_zone       = data.aws_availability_zones.available.names[0]
    map_public_ip_on_launch = true   # ✅ clé pour rendre public

    tags = {
    Name = "public-subnet"
    }
}

# Route Table (pour Internet)
resource "aws_route_table" "public" {
    vpc_id = aws_vpc.main.id

    route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
    }

    tags = {
    Name = "public-rt"
    }
}

# Association de la Route Table au Subnet public
resource "aws_route_table_association" "public_assoc" {
    subnet_id      = aws_subnet.public.id
    route_table_id = aws_route_table.public.id
}


# =====
# Subnet private
resource "aws_subnet" "private" {
    vpc_id                  = aws_vpc.main.id
    cidr_block              = "10.0.2.0/24"
    availability_zone       = data.aws_availability_zones.available.names[0]
    map_public_ip_on_launch = false

    tags = {
    Name = "private-subnet"
    }
}

# Private Route Table  (pour Internet)
resource "aws_route_table" "private" {
    vpc_id = aws_vpc.main.id

    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = aws_nat_gateway.nat.id
    }

    tags = {
        Name = "private-rt"
    }
}

# Association de la Route Table au Subnet public
resource "aws_route_table_association" "private_assoc" {
    subnet_id      = aws_subnet.private.id
    route_table_id = aws_route_table.private.id
}


########################
# Security Groups
########################
# Front : HTTP public + SSH depuis ta machine
resource "aws_security_group" "sg_front" {
    name        = "sg-front"
    description = "Front HTTP/SSH"
    vpc_id      = aws_vpc.main.id

    ingress {
        description = "HTTP"
        from_port   = 80
        to_port     = 80
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    ingress {
        description = "SSH"
        from_port   = 22
        to_port     = 22
        protocol    = "tcp"
        cidr_blocks = [var.my_ip]
    }

    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }

    tags = { Name = "sg-front" }
}

resource "aws_security_group" "sg_back" {
    name        = "sg-back"
    description = "Back app/SSH"
    vpc_id      = aws_vpc.main.id

    # Appli (8080) accessible UNIQUEMENT depuis le SG du front
    ingress {
        description              = "App from front"
        from_port                = 8080
        to_port                  = 8080
        protocol                 = "tcp"
        security_groups          = [aws_security_group.sg_front.id]
    }

    # SSH depuis ta machine
    ingress {
        description = "SSH"
        from_port   = 22
        to_port     = 22
        protocol    = "tcp"
        cidr_blocks = [var.my_ip]
    }

    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }

    tags = { Name = "sg-back" }
}


########################
# Instances
########################
resource "aws_instance" "front" {
    ami                         = data.aws_ami.al2.id
    instance_type               = "t3.micro"
    subnet_id                   = aws_subnet.public.id
    vpc_security_group_ids      = [aws_security_group.sg_front.id]
    key_name                    = var.key_name
    associate_public_ip_address = true   # dans un subnet public, c'est logique

    user_data = <<-EOF
    #!/bin/bash
    yum install -y httpd
    echo "Hello from FRONT" > /var/www/html/index.html
    systemctl enable httpd
    systemctl start httpd
    EOF

    tags = { Name = "ec2-front" }
}

# Back
resource "aws_instance" "back" {
    ami                         = data.aws_ami.al2.id
    instance_type               = "t3.micro"
    subnet_id                   = aws_subnet.back.id
    vpc_security_group_ids      = [aws_security_group.sg_back.id]
    key_name                    = var.key_name
    associate_public_ip_address = false

    user_data = <<-EOF
    #!/bin/bash
    cat >/usr/local/bin/app.sh <<'EOT'
    #!/bin/bash
    while true; do { echo -e 'HTTP/1.1 200 OK\r\n'; echo 'Hello from BACK'; } | nc -l -p 8080 -q 1; done
    EOT
    chmod +x /usr/local/bin/app.sh
    yum install -y nc
    nohup /usr/local/bin/app.sh &
    EOF

    tags = { Name = "ec2-back" }
}