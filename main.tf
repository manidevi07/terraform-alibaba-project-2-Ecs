/* DERIVED --------------------------------------*/

locals {
  stage  = terraform.workspace
  tokens = split(".", local.stage)
  dc     = "${var.provider_name}"
  /* convert ports to port ranges, as requried by port_range argument */
  tcp_ports = [
    for port in var.open_tcp_ports:
    (replace(port, "-", "/") != port ? replace(port, "-", "/") : "${port}/${port}" )
  ]
  udp_ports = [
    for port in var.open_udp_ports:
    (replace(port, "-", "/") != port ? replace(port, "-", "/") : "${port}/${port}" )
  ]
  /* always add SSH, Tinc, Netdata, and Consul to allowed ports */
  open_tcp_ports = concat(["22/22", "655/655", "8000/8000", "8301/8301"], local.tcp_ports)
  open_udp_ports = concat(["655/655","8301/8301"], local.udp_ports)
}

/* RESOURCES ------------------------------------*/

/* Creating our VPC */
resource "alicloud_vpc" "ecs-vpc" {
  name       = "vpc1"
  cidr_block = "192.168.0.0/16"

}

data "alicloud_zones" "abc_zones" {}

/* Creating our vswitch */
resource "alicloud_vswitch" "ecs-vswitch" {
  name              = "vswitch1"
  vpc_id            = "${alicloud_vpc.ecs-vpc.id}"
  cidr_block        = "192.168.0.0/24"
  availability_zone = "${data.alicloud_zones.abc_zones.zones.0.id}"

}
resource "alicloud_security_group" "host" {
  name        = "sg-${var.env}-${local.stage}"
  description = "Sec Group via Terraform"
  vpc_id      = "${alicloud_vpc.ecs-vpc.id}"


/* protocol with port_range option */
resource "alicloud_security_group_rule" "icmp" {
  security_group_id = alicloud_security_group.host.id
  type              = "ingress"
  ip_protocol       = "icmp"
  cidr_ip           = "0.0.0.0/0"
}

resource "alicloud_security_group_rule" "tcp" {
  security_group_id = alicloud_security_group.host.id
  type              = "ingress"
  ip_protocol       = "tcp"
  cidr_ip           = "0.0.0.0/0"
  port_range        = replace(local.open_tcp_ports[count.index], "-", "/")
  count             = length(local.open_tcp_ports)
}

resource "alicloud_security_group_rule" "udp" {
  security_group_id = alicloud_security_group.host.id
  type              = "ingress"
  ip_protocol       = "udp"
  cidr_ip           = "0.0.0.0/0"
  port_range        = replace(local.open_udp_ports[count.index], "-", "/")
  count             = length(local.open_udp_ports)
}

resource "alicloud_security_group_rule" "blocked_ips" {
  security_group_id = alicloud_security_group.host.id
  type              = "ingress"
  ip_protocol       = "all"
  cidr_ip           = var.blocked_ips[count.index]
  count             = length(var.blocked_ips)
}

data "alicloud_images" "host" {
  owners     = "self"
  name_regex = var.image
}

resource "alicloud_instance" "host" {
  host_name     = "${var.name}-${format("%02d", count.index + 1)}.${local.dc}.${var.env}.${local.stage}"
  instance_name = "${var.name}-${format("%02d", count.index + 1)}.${local.dc}.${var.env}.${local.stage}"

  security_groups = [alicloud_security_group.host.id]
  image_id        = data.alicloud_images.host.images[0].id
  vswitch_id      = "${alicloud_vswitches.ecs-vswitch.id}"

  tags = {
    stage = local.stage
    group = var.group
    env   = var.env
  }

  key_name             = var.key_pair
  availability_zone    = var.zone
  instance_type        = var.type
  system_disk_category = var.disk
  count                = var.host_count

  /* costs */
  instance_charge_type = var.charge
  period_unit          = var.period
  /* NOTE: We provision inside Elastic IP association */
}

/* Optional resource when vol_size is set */
resource "alicloud_disk" "host" {
  # cn-beijing
  availability_zone = var.zone
  name              = "data.${var.name}-${format("%02d", count.index + 1)}.${local.dc}.${var.env}.${local.stage}"
  description       = "Extra data volume created by Terraform."
  category          = "cloud_ssd"
  size              = var.vol_size
  count             = var.vol_size > 0 ? var.host_count : 0

  tags = {
    stage = local.stage
    group = var.group
    env   = var.env
  }
}

resource "alicloud_disk_attachment" "host" {
  disk_id     = alicloud_disk.host[0].id
  instance_id = alicloud_instance.host[0].id
  count       = var.vol_size > 0 ? var.host_count : 0
}

resource "alicloud_eip" "host" {
  count     = var.host_count
  bandwidth = var.max_band_out
  lifecycle {
    prevent_destroy = true
  }
}

/**
 * WARNING: This is broken when instance has a public_ip
 * https://www.alibabacloud.com/help/doc-detail/72125.htm
 * "The ECS instance does not have a public IP, nor is it bound to any EIP."
 * https://www.terraform.io/docs/providers/alicloud/r/eip_association.html
 **/
resource "alicloud_eip_association" "host" {
  allocation_id = alicloud_eip.host[count.index].id
  instance_id   = alicloud_instance.host[count.index].id
  count         = var.host_count

  /**
   * It is necessary to provision here instead of in alicloud_instance
   * because Alibaba Cloud instances do not have public IPs by default
   **/
  provisioner "ansible" {
    connection {
      host = alicloud_eip.host[count.index].ip_address
      user = var.ssh_user
    }

    plays {
      playbook {
        file_path = "${path.cwd}/ansible/bootstrap.yml"
      }

      hosts  = [alicloud_instance.host[count.index].public_ip]
      groups = [var.group]

      extra_vars = {
        hostname         = alicloud_instance.host[count.index].host_name
        ansible_ssh_user = var.ssh_user
        data_center      = local.dc
        stage            = local.stage
        env              = var.env
      }
    }
  }
}


resource "ansible_host" "host" {
  inventory_hostname = alicloud_instance.host[count.index].host_name

  groups = [var.group, local.dc]
  count  = var.host_count

  vars = {
    ansible_host = alicloud_eip.host[count.index].ip_address
    hostname     = alicloud_instance.host[count.index].host_name
    region       = alicloud_instance.host[count.index].availability_zone
    dns_entry    = "${alicloud_instance.host[count.index].host_name}.${var.domain}"
    dns_domain   = var.domain
    data_center  = local.dc
    stage        = local.stage
    env          = var.env
  }
}

