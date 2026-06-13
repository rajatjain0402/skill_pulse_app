variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.medium"
}

variable "ssh_ingress_cidr" {
  description = "CIDR allowed to SSH (port 22). Open to the world by default for course simplicity — lock down for real use."
  type        = string
  default     = "0.0.0.0/0"
}

variable "key_pair_name" {
  description = "Name for the AWS key pair"
  type        = string
  default     = "skillpulse-key"
}

variable "repo_url" {
  description = "Public GitHub repo URL containing the SkillPulse code (cloned by user_data on first boot). Example: https://github.com/<user>/<repo>.git"
  type        = string
}

variable "dockerhub_username" {
  description = "Docker Hub username — written into .env on the EC2 box so docker compose can pull the backend image"
  type        = string
}
