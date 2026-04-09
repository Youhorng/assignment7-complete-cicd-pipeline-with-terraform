variable "aws_region" {
  type        = string
  description = "AWS region"
  default     = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "feane"
}

variable "image_uri" {
  type        = string
  description = "Full ghcr.io image URI to deploy on EC2"
}

variable "ami_id" {
  type        = string
  description = "Ubuntu AMI ID for EC2 instances (region-specific)"
  default     = "ami-0ec10929233384c7f"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "asg_min_size" {
  type    = number
  default = 2
}

variable "asg_desired_capacity" {
  type    = number
  default = 2
}

variable "asg_max_size" {
  type    = number
  default = 4
}
