terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# ECS Cluster
resource "aws_ecs_cluster" "api_cluster" {
  name = "terraform-api-cluster"
}

# Use the existing AWS Academy IAM role
data "aws_iam_role" "lab_role" {
  name = "LabRole"
}

# Define the Docker container ECS will run
resource "aws_ecs_task_definition" "api_task" {
  family                   = "terraform-api-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  execution_role_arn = data.aws_iam_role.lab_role.arn
  task_role_arn      = data.aws_iam_role.lab_role.arn

  container_definitions = jsonencode([
    {
      name      = "flask-api"
      image     = "bubbaj/it4200-fall-2026:2.36.0"
      essential = true

      portMappings = [
        {
          containerPort = 8000
          hostPort      = 8000
          protocol      = "tcp"
        }
      ]
    }
  ])
}

# VPC
resource "aws_vpc" "api_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "terraform-api-vpc"
  }
}

# Public Subnet 1
resource "aws_subnet" "public_1" {
  vpc_id                  = aws_vpc.api_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "terraform-public-1"
  }
}

# Public Subnet 2
resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.api_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true

  tags = {
    Name = "terraform-public-2"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "api_igw" {
  vpc_id = aws_vpc.api_vpc.id
}

# Public Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.api_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.api_igw.id
  }
}

# Associate Subnets with Route Table
resource "aws_route_table_association" "public_1" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}

# Load Balancer Security Group
resource "aws_security_group" "alb_sg" {
  name        = "terraform-alb-sg"
  description = "Allow HTTP traffic to the load balancer"
  vpc_id      = aws_vpc.api_vpc.id

  ingress {
    description = "HTTP access"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "terraform-alb-sg"
  }
}

# ECS Container Security Group
resource "aws_security_group" "ecs_sg" {
  name        = "terraform-ecs-sg"
  description = "Allow traffic from ALB to Flask API"
  vpc_id      = aws_vpc.api_vpc.id

  ingress {
    description     = "Flask API traffic from ALB"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    description = "Allow outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "terraform-ecs-sg"
  }
}

# Application Load Balancer
resource "aws_lb" "api_alb" {
  name               = "terraform-api-alb"
  internal           = false
  load_balancer_type = "application"

  security_groups = [aws_security_group.alb_sg.id]

  subnets = [
    aws_subnet.public_1.id,
    aws_subnet.public_2.id
  ]
}

# Target Group
resource "aws_lb_target_group" "api_tg" {
  name        = "terraform-api-tg"
  port        = 8000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.api_vpc.id

  health_check {
    enabled             = true
    path                = "/microwave"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# HTTP Listener
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.api_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api_tg.arn
  }
}

# Public URL for the deployed API
output "load_balancer_dns_name" {
  description = "Public DNS name of the API load balancer"
  value       = aws_lb.api_alb.dns_name
}

# ECS Service
resource "aws_ecs_service" "api_service" {
  name            = "terraform-api-service"
  cluster         = aws_ecs_cluster.api_cluster.id
  task_definition = aws_ecs_task_definition.api_task.arn

  desired_count = 1
  launch_type   = "FARGATE"

  network_configuration {
    subnets = [
      aws_subnet.public_1.id,
      aws_subnet.public_2.id
    ]

    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api_tg.arn
    container_name   = "flask-api"
    container_port   = 8000
  }

  depends_on = [
    aws_lb_listener.http
  ]
}