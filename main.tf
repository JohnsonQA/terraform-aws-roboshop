# Creating a module for Terraform frontend and backend components

resource "aws_lb_target_group" "main" {
  name     = "${var.project}-${var.environment}-${var.component}" #roboshop-dev-catalogue
  port     = local.tg_port                                       
  protocol = "HTTP"
  vpc_id   = local.vpc_id
  deregistration_delay = 120            
  health_check {
    healthy_threshold = 2     
    interval = 5              
    matcher = "200-299"       
    path = local.health_check_path   
    port = local.tg_port               
    timeout = 2               
    unhealthy_threshold = 3 
  }
}

# Creating instances for all the components
resource "aws_instance" "main" {
  ami           = local.ami_id
  instance_type = "t3.micro"
  vpc_security_group_ids = [local.sg_id]
  subnet_id = local.private_subnet_id         #Since we are using public subnet for alb and its secured we can use private for both frontend and backedn services
  #iam_instance_profile = "EC2RoleToFetchSSMParams"
  tags = merge(
    local.common_tags,
    {
        Name = "${var.project}-${var.environment}-${var.component}"
    }
  )
}

#Provisoning the services into the instance
resource "terraform_data" "main" {
  triggers_replace = [
    aws_instance.main.id
  ]
  
  provisioner "file" {
    source      = "bootstrap.sh"
    destination = "/tmp/${var.component}.sh"
  }

  connection {
    type     = "ssh"
    user     = "ec2-user"
    password = "DevOps321"
    host     = aws_instance.main.private_ip
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/${var.component}.sh",
      "sudo sh /tmp/${var.component}.sh ${var.component} ${var.environment}"
    ]
  }
}

#Auto Scaling. To do it first stop the instance
resource "aws_ec2_instance_state" "main"{
  instance_id = aws_instance.main.id
  state = "stopped"
  depends_on = [terraform_data.main]  #Once provisoning is done then we need to stop the instance
}

# Get the AMI Id of the instance
resource "aws_ami_from_instance" "main" {
  name               = "${var.project}-${var.environment}-${var.component}"
  source_instance_id = aws_instance.main.id
  depends_on = [aws_ec2_instance_state.main]   #Once stopped only then we need to get the AMI ID
  tags = merge(
    local.common_tags,
    {
      Name = "${var.project}-${var.environment}-${var.component}"
    }
  )
}

#Delete the instance 
resource "terraform_data" "main_delete" {
  triggers_replace = [
    aws_instance.main.id
  ]
  
  # make sure you have aws CLI configure in your laptop. localexec because instance already stopped and no use
  #ssh cannot be done since it is stopped. safe way is doing it using localexec to delete the instance outside of provider
  provisioner "local-exec" {
    command = "aws ec2 terminate-instances --instance-ids ${aws_instance.main.id}"
  }

  depends_on = [aws_ami_from_instance.main]     #Once ami is feteched ony then delete the instance
}

# Launch Template
resource "aws_launch_template" "main" {
  name = "${var.project}-${var.environment}-${var.component}"
  image_id = aws_ami_from_instance.main.id          #AMI ID of catalogue
  instance_initiated_shutdown_behavior = "terminate"     #It should be terminated once get the AMI ID 
  instance_type = "t3.micro"
  vpc_security_group_ids = [local.sg_id]        # SG id of services
  update_default_version = true # each time you update, new version will become default
  tag_specifications {
    resource_type = "instance"
    # EC2 tags created by ASG
    tags = merge(
      local.common_tags,
      {
        Name = "${var.project}-${var.environment}-${var.component}"
      }
    )
  }

  # volume tags created by ASG
  tag_specifications {
    resource_type = "volume"

    tags = merge(
      local.common_tags,
      {
        Name = "${var.project}-${var.environment}-${var.component}"
      }
    )
  }

  # launch template tags
  tags = merge(
      local.common_tags,
      {
        Name = "${var.project}-${var.environment}-${var.component}"
      }
  )

}

#Auto Sacling Creation
resource "aws_autoscaling_group" "main" {
  name                 = "${var.project}-${var.environment}-${var.component}"
  desired_capacity   = 1                                      #How many instances we want to launch
  max_size           = 10                                     #Max instances to scale up and scale down
  min_size           = 1                                      #Min instance
  target_group_arns = [aws_lb_target_group.main.arn]     #To which target group we need to attach
  vpc_zone_identifier  = local.private_subnet_ids             #In how many zones we should have instances. 
  health_check_grace_period = 90                             #within how many secs health check should start
  health_check_type         = "ELB"                          #Should be done by ALB

  launch_template {
    id      = aws_launch_template.main.id              #Launch Temp ID
    version = aws_launch_template.main.latest_version   #Latest Version as everytime AMI ID changes 
  }

  dynamic "tag" {
    for_each = merge(
      local.common_tags,
      {
        Name = "${var.project}-${var.environment}-${var.component}"
      }
    )
    content{
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
    
  }

  #When any changes done in AMI or ASG launch template, instances would be auto refreshed based on rolling strategy it means it replaces gradually not all at once. 
  #Means one or more instances will be terminated and replaced at a time
  instance_refresh {
    strategy = "Rolling" 
    preferences {
      min_healthy_percentage = 50     #During Refresh atleast 50% of instances must be healthy
    }
    triggers = ["launch_template"]     #Based on launch template updates or changes instance trigger the instance refresh
  }

  timeouts{
    delete = "15m"                     #It deletes the instance within 15mins 
  }
}

#Auto Scaling Policy
resource "aws_autoscaling_policy" "main" {
  name                   = "${var.project}-${var.environment}-${var.component}"
  autoscaling_group_name = aws_autoscaling_group.main.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = 75.0
  }
}

#ALB Listener Rule for Catalogue Service
resource "aws_lb_listener_rule" "main" {
  listener_arn = local.alb_listener_arn
  priority     = var.rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn  # Forwarsd to Catalogue TG
  }

  condition {
    host_header {
      values = [local.rule_header_url]    #When hits tis url then proceed it to TG
    }
  }
}