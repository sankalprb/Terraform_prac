provider "aws"{
	region = "ap-south-1"
	profile = "srborg"
}

//creating vpc

resource "aws_vpc" "taskvpc" {
  cidr_block       = "10.0.0.0/16"
  instance_tenancy = "default"
  tags = {
    Name = "Task"
  }
}

//creating internet gateway to allow connection to VPC and hence the instance

resource "aws_internet_gateway" "gateway" {
  vpc_id = "${aws_vpc.taskvpc.id}"

  tags = {
    description = "allow connection to VPC"
  }
}

//route table for inbound traffic to vpc through gateway

resource "aws_route_table" "r" {
  vpc_id = "${aws_vpc.taskvpc.id}"

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.gateway.id}"
  }

  tags = {
    description = "route table for inbound traffic to vpc"
  }
  depends_on = [
	aws_internet_gateway.gateway
]
}

//setting main route table

resource "aws_main_route_table_association" "a" {
  vpc_id         = "${aws_vpc.taskvpc.id}"
  route_table_id = "${aws_route_table.r.id}"
  depends_on = [
	aws_route_table.r
]
}

//creating a new subnet

resource "aws_subnet" "tasksub" {
  vpc_id     = aws_vpc.taskvpc.id
  availability_zone = "ap-south-1a"
  cidr_block = "10.0.1.0/24"
  map_public_ip_on_launch = true

  tags = {
    Name = "tasksub"
  }
  depends_on = [
	aws_vpc.taskvpc
]
}

//creating an association between route table and subnet

resource "aws_route_table_association" "associate" {
  subnet_id      = aws_subnet.tasksub.id
  route_table_id = aws_route_table.r.id
  depends_on = [
	aws_subnet.tasksub , aws_route_table.r 
]
}


//creating 1gb ebs volume

resource "aws_ebs_volume" "myebs" {
  availability_zone = aws_instance.webserver.availability_zone
  size              = 1

  tags = {
    Name = "taskebs"
  }
  depends_on = [
	aws_instance.webserver
]
}

//security group allowing SSH, HTTP and HTTPS protocols

resource "aws_security_group" "task" {
  name        = "taskfw"
  description = "Allow SSH and Port 80"
  vpc_id      = aws_vpc.taskvpc.id

  ingress {
    from_port   = 80
    to_port     =  80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     =  443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     =  22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] 
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "Task1FirewallT"
  }
depends_on = [
	aws_vpc.taskvpc
]
}

//generating a private_key

resource "tls_private_key" "mykey" {
  algorithm = "RSA"
  depends_on = [
	aws_security_group.task
]
}

//creating an aws_key_pair

resource "aws_key_pair" "taskK" {
  key_name   = "TaskKey"
  public_key = tls_private_key.mykey.public_key_openssh 
  depends_on = [
    tls_private_key.mykey
  ]
}

//s3 bucket to store image

resource "aws_s3_bucket" "taskbucket" {
  bucket = "taskenvbucket123"
  acl    = "public-read"

  tags = {
    Name        = "My Task bucket"
  }
}

//uploading image to s3 bucket

resource "aws_s3_bucket_object" "object" {
  bucket = aws_s3_bucket.taskbucket.bucket
  key    = "taskobject.jpg"
  source = "C:/Users/sanka/Pictures/task.jpg"
  content_type = "image/jpg"
  acl = "public-read"
  depends_on = [
	aws_s3_bucket.taskbucket
]
}

//using CDN network for static content by creating a cloudfront distribution

locals {
  s3_origin_id = "new_s3_task"
}

resource "aws_cloudfront_distribution" "task_distribution" {
  origin {
    domain_name = "${aws_s3_bucket.taskbucket.bucket_regional_domain_name}"
    origin_id   = "${local.s3_origin_id}"
  }

  enabled             = true
  is_ipv6_enabled     = true

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "${local.s3_origin_id}"

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "allow-all"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Environment = "task"
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
  depends_on = [
	 aws_s3_bucket_object.object
]
}

//launching AMAZON LINUX 2 t2.micro instance

resource "aws_instance" "webserver" {
  ami           = "ami-0447a12f28fddb066"
  instance_type = "t2.micro"
  key_name = aws_key_pair.taskK.key_name
  vpc_security_group_ids = ["${aws_security_group.task.id}"]
  subnet_id = aws_subnet.tasksub.id 

  connection {
    type     = "ssh"
    user     = "ec2-user"
    private_key = tls_private_key.mykey.private_key_pem
    host     = aws_instance.webserver.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "sudo yum install httpd  php git -y",
      "sudo systemctl start httpd",
      "sudo systemctl enable httpd",
    ]
  }

  tags = {
    Name = "taskos"
  }
  depends_on = [
	aws_key_pair.taskK
]
}

//output public ip

output "publicip" {
  value = aws_instance.webserver.public_ip
}

//attaching the 1gb storage and cloning the repository

resource "aws_volume_attachment" "ebsattach" {
  device_name = "/dev/sdf"
  volume_id   = "${aws_ebs_volume.myebs.id}"
  instance_id = "${aws_instance.webserver.id}"
  force_detach = true

  connection {
    type     = "ssh"
    user     = "ec2-user"
    private_key = tls_private_key.mykey.private_key_pem
    host     = aws_instance.webserver.public_ip
  }

provisioner "remote-exec" {
    inline = [
      "sudo mkfs.ext4  /dev/xvdf",
      "sudo mount  /dev/xvdf  /var/www/html",
      "sudo rm -rf /var/www/html/*",
      "sudo git clone https://github.com/sankalprb/Terraform_Task1.git /var/www/html/"
    ]
  }

  depends_on = [
	aws_instance.webserver
]
}

//adding image to html code using cloudfront url

resource "null_resource" "image"  {
depends_on = [
    aws_instance.webserver, aws_cloudfront_distribution.task_distribution, aws_volume_attachment.ebsattach
  ]
connection {
    type     = "ssh"
    user     = "ec2-user"
    private_key = tls_private_key.mykey.private_key_pem
    host     = aws_instance.webserver.public_ip
  }
  provisioner "remote-exec" {
    inline = [
	"echo '<img src='https://${aws_cloudfront_distribution.task_distribution.domain_name}/taskobject.jpg' width='600' height='200'>'  | sudo tee -a /var/www/html/index.php"
]
  }
}

//opening page in chrome

resource "null_resource" "chrome"  {


depends_on = [
    null_resource.image
  ]

	provisioner "local-exec" {
	    command = "start chrome ${aws_instance.webserver.public_ip}"
  	}
}
output "cd__dns"{
	value = aws_cloudfront_distribution.task_distribution.domain_name
}


