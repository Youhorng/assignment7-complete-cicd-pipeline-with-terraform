output "alb_dns_name" {
  value       = aws_lb.this.dns_name
  description = "Public DNS name of the ALB, open this in browser"
}
