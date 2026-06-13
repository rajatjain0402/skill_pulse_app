output "ec2_public_ip" {
  description = "Public IP — paste into the EC2_HOST GitHub secret"
  value       = aws_instance.this.public_ip
}

output "ec2_user" {
  description = "SSH username — paste into the EC2_USER GitHub secret"
  value       = "ubuntu"
}

output "ssh_private_key" {
  description = "Private key. Run `terraform output -raw ssh_private_key > skillpulse-key.pem && chmod 600 skillpulse-key.pem`, then paste the file's contents into the EC2_SSH_KEY GitHub secret."
  value       = tls_private_key.this.private_key_pem
  sensitive   = true
}

output "app_url" {
  description = "URL where SkillPulse will be live after the first CI/CD run"
  value       = "http://${aws_instance.this.public_ip}"
}
