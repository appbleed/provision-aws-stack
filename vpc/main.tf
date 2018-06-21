/*
CIDR (Classless Inter-Domain Routing) notation is a compact representation of an IP address and its associated routing prefix.
Before the implementation of CIDR, IPv4 networks were represented by the starting address and the subnet mask, both written in dot-decimal notation.
Thus, 192.168.100.0/24 was often written as 192.168.100.0/255.255.255.0.
In CIDR an address or routing prefix is written with a suffix indicating the number of bits of the prefix, such as 192.168.2.0/24 for IPv4, and 2001:db8::/32 for IPv6
*/
variable "cidr" {
  description = "The CIDR block for the VPC."
}
/*
A subnetwork or subnet is a logical subdivision of an IP network
Traffic is exchanged between subnetworks through routers. A router serves as a logical or physical boundary between the subnets.
Resources in external subnet can talk to external network like internet via internet gateway.
*/
variable "external_subnets" {
  description = "List of external subnets"
  type        = "list"
}

variable "internal_subnets" {
  description = "List of internal subnets"
  type        = "list"
}
/*
Tag each resource with environment for managing, monitoring and billing purpose.
*/
variable "environment" {
  description = "Environment tag, e.g prod"
}

/*
All public cloud service providers physically host their infrastructure in multiple locations world-wide. These locations are composed of regions and Availability Zones.
Each region is a separate geographic area. Each region has multiple, isolated locations known as Availability Zones.
Cloud service providers gives you the ability to place resources, such as instances, and data in multiple locations. Resources aren't replicated across regions unless you do so specifically.
*/
variable "availability_zones" {
  description = "List of availability zones"
  type        = "list"
}

/*
tag your resource with a name
*/
variable "name" {
  description = "Name tag, e.g stack"
  default     = "stack"
}

/*
Nat
You can use a NAT device to enable instances in a private subnet to connect to the Internet (for example, for software updates) or other AWS services,
but prevent the Internet from initiating connections with the instances. A NAT device forwards traffic from the instances in the private subnet to the Internet or other AWS services,
and then sends the response back to the instances. When traffic goes to the Internet, the source IPv4 address is replaced with the NAT device’s address and similarly,
when the response traffic goes to those instances, the NAT device translates the address back to those instances’ private IPv4 addresses.

https://docs.aws.amazon.com/AmazonVPC/latest/UserGuide/vpc-nat.html

*/
variable "use_nat_instances" {
  description = "If true, use EC2 NAT instances instead of the AWS NAT gateway service."
  default     = false
}

variable "nat_instance_type" {
  description = "Only if use_nat_instances is true, which EC2 instance type to use for the NAT instances."
  default     = "t2.nano"
}

variable "use_eip_with_nat_instances" {
  description = "Only if use_nat_instances is true, whether to assign Elastic IPs to the NAT instances. IF this is set to false, NAT instances use dynamically assigned IPs."
  default     = false
}

# This data source returns the newest Amazon NAT instance AMI
data "aws_ami" "nat_ami" {
  most_recent = true

  filter {
    name   = "owner-alias"
    values = ["amazon"]
  }

  filter {
    name   = "name"
    values = ["amzn-ami-vpc-nat*"]
  }
}

variable "nat_instance_ssh_key_name" {
  description = "Only if use_nat_instance is true, the optional SSH key-pair to assign to NAT instances."
  default     = ""
}

/**
 * VPC
 A virtual private cloud (VPC) is a virtual network dedicated to your AWS account. It is logically isolated from other virtual networks in the AWS Cloud.
 You can launch your AWS resources, such as Amazon EC2 instances, into your VPC.
 When you create a VPC, you must specify a range of IPv4 addresses for the VPC in the form of a Classless Inter-Domain Routing (CIDR) block; for example, 10.0.0.0/16
 */

resource "aws_vpc" "main" {
  cidr_block           = "${var.cidr}"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags {
    Name        = "${var.name}"
    Environment = "${var.environment}"
  }
}

/**
 * Gateways
 An Internet gateway is a horizontally scaled, redundant, and highly available VPC component that allows communication between instances in your VPC and the Internet.
 It therefore imposes no availability risks or bandwidth constraints on your network traffic.
 An Internet gateway serves two purposes: to provide a target in your VPC route tables for Internet-routable traffic,
 and to perform network address translation (NAT) for instances that have been assigned public IPv4 addresses.
 https://docs.aws.amazon.com/AmazonVPC/latest/UserGuide/VPC_Internet_Gateway.html
 */

resource "aws_internet_gateway" "main" {
  vpc_id = "${aws_vpc.main.id}"

  tags {
    Name        = "${var.name}"
    Environment = "${var.environment}"
  }
}

/*
You can use a network address translation (NAT) gateway to enable instances in a private subnet to connect to the internet or other AWS services,
but prevent the internet from initiating a connection with those instances.
https://docs.aws.amazon.com/AmazonVPC/latest/UserGuide/vpc-nat-gateway.html
*/
resource "aws_nat_gateway" "main" {
  # Only create this if not using NAT instances.
  count         = "${(1 - var.use_nat_instances) * length(var.internal_subnets)}"
  allocation_id = "${element(aws_eip.nat.*.id, count.index)}"
  subnet_id     = "${element(aws_subnet.external.*.id, count.index)}"
  depends_on    = ["aws_internet_gateway.main"]
}

/*
An Elastic IP address is a static, public IPv4 address designed for dynamic cloud computing. You can associate an Elastic IP address with any instance or network interface
for any VPC in your account. With an Elastic IP address, you can mask the failure of an instance by rapidly remapping the address to another instance in your VPC.
*/
resource "aws_eip" "nat" {
  # Create these only if:
  # NAT instances are used and Elastic IPs are used with them,
  # or if the NAT gateway service is used (NAT instances are not used).
  count = "${signum((var.use_nat_instances * var.use_eip_with_nat_instances) + (var.use_nat_instances == 0 ? 1 : 0)) * length(var.internal_subnets)}"

  vpc = true
}
/*
A security group acts as a virtual firewall for your instance to control inbound and outbound traffic. When you launch an instance in a VPC,
you can assign up to five security groups to the instance. Security groups act at the instance level, not the subnet level.
Therefore, each instance in a subnet in your VPC could be assigned to a different set of security groups. If you don't specify a particular group at launch time,
the instance is automatically assigned to the default security group for the VPC.
A rule applies either to inbound traffic (ingress) or outbound traffic (egress). You can grant access to a specific CIDR range, or to another security group in your VPC or in a peer VPC
https://docs.aws.amazon.com/AmazonVPC/latest/UserGuide/VPC_SecurityGroups.html
*/
resource "aws_security_group" "nat_instances" {
  # Create this only if using NAT instances, vs. the NAT gateway service.
  count       = "${0 + var.use_nat_instances}"
  name        = "nat"
  description = "Allow traffic from clients into NAT instances"

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "udp"
    cidr_blocks = "${var.internal_subnets}"
  }

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = "${var.internal_subnets}"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  vpc_id = "${aws_vpc.main.id}"
}

resource "aws_instance" "nat_instance" {
  # Create these only if using NAT instances, vs. the NAT gateway service.
  count             = "${(0 + var.use_nat_instances) * length(var.internal_subnets)}"
  availability_zone = "${element(var.availability_zones, count.index)}"

  tags {
    Name        = "${var.name}-${format("internal-%03d NAT", count.index+1)}"
    Environment = "${var.environment}"
  }

  volume_tags {
    Name        = "${var.name}-${format("internal-%03d NAT", count.index+1)}"
    Environment = "${var.environment}"
  }

  key_name          = "${var.nat_instance_ssh_key_name}"
  ami               = "${data.aws_ami.nat_ami.id}"
  instance_type     = "${var.nat_instance_type}"
  source_dest_check = false

  # associate_public_ip_address is not used,,
  # as public subnets have map_public_ip_on_launch set to true.
  # Also, using associate_public_ip_address causes issues with
  # stopped NAT instances which do not use an Elastic IP.
  # - For more details: https://github.com/terraform-providers/terraform-provider-aws/issues/343
  subnet_id = "${element(aws_subnet.external.*.id, count.index)}"

  vpc_security_group_ids = ["${aws_security_group.nat_instances.id}"]

  lifecycle {
    # Ignore changes to the NAT AMI data source.
    ignore_changes = ["ami"]
  }
}

resource "aws_eip_association" "nat_instance_eip" {
  # Create these only if using NAT instances, vs. the NAT gateway service.
  count         = "${(0 + (var.use_nat_instances * var.use_eip_with_nat_instances)) * length(var.internal_subnets)}"
  instance_id   = "${element(aws_instance.nat_instance.*.id, count.index)}"
  allocation_id = "${element(aws_eip.nat.*.id, count.index)}"
}

/**
 * Subnets.
 */

resource "aws_subnet" "internal" {
  vpc_id            = "${aws_vpc.main.id}"
  cidr_block        = "${element(var.internal_subnets, count.index)}"
  availability_zone = "${element(var.availability_zones, count.index)}"
  count             = "${length(var.internal_subnets)}"

  tags {
    Name        = "${var.name}-${format("internal-%03d", count.index+1)}"
    Environment = "${var.environment}"
  }
}

resource "aws_subnet" "external" {
  vpc_id                  = "${aws_vpc.main.id}"
  cidr_block              = "${element(var.external_subnets, count.index)}"
  availability_zone       = "${element(var.availability_zones, count.index)}"
  count                   = "${length(var.external_subnets)}"
  map_public_ip_on_launch = true

  tags {
    Name        = "${var.name}-${format("external-%03d", count.index+1)}"
    Environment = "${var.environment}"
  }
}

/**
 * Route tables
 A route table contains a set of rules, called routes, that are used to determine where network traffic is directed.
 Each subnet in your VPC must be associated with a route table; the table controls the routing for the subnet.
 A subnet can only be associated with one route table at a time, but you can associate multiple subnets with the same route table.
 https://docs.aws.amazon.com/AmazonVPC/latest/UserGuide/VPC_Route_Tables.html
 */

resource "aws_route_table" "external" {
  vpc_id = "${aws_vpc.main.id}"

  tags {
    Name        = "${var.name}-external-001"
    Environment = "${var.environment}"
  }
}

resource "aws_route" "external" {
  route_table_id         = "${aws_route_table.external.id}"
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = "${aws_internet_gateway.main.id}"
}

resource "aws_route_table" "internal" {
  count  = "${length(var.internal_subnets)}"
  vpc_id = "${aws_vpc.main.id}"

  tags {
    Name        = "${var.name}-${format("internal-%03d", count.index+1)}"
    Environment = "${var.environment}"
  }
}

resource "aws_route" "internal" {
  # Create this only if using the NAT gateway service, vs. NAT instances.
  count                  = "${(1 - var.use_nat_instances) * length(compact(var.internal_subnets))}"
  route_table_id         = "${element(aws_route_table.internal.*.id, count.index)}"
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = "${element(aws_nat_gateway.main.*.id, count.index)}"
}

resource "aws_route" "internal_nat_instance" {
  count                  = "${(0 + var.use_nat_instances) * length(compact(var.internal_subnets))}"
  route_table_id         = "${element(aws_route_table.internal.*.id, count.index)}"
  destination_cidr_block = "0.0.0.0/0"
  instance_id            = "${element(aws_instance.nat_instance.*.id, count.index)}"
}

/**
 * Route associations
 */

resource "aws_route_table_association" "internal" {
  count          = "${length(var.internal_subnets)}"
  subnet_id      = "${element(aws_subnet.internal.*.id, count.index)}"
  route_table_id = "${element(aws_route_table.internal.*.id, count.index)}"
}

resource "aws_route_table_association" "external" {
  count          = "${length(var.external_subnets)}"
  subnet_id      = "${element(aws_subnet.external.*.id, count.index)}"
  route_table_id = "${aws_route_table.external.id}"
}

/**
 * Outputs
 */

// The VPC ID
output "id" {
  value = "${aws_vpc.main.id}"
}

// The VPC CIDR
output "cidr_block" {
  value = "${aws_vpc.main.cidr_block}"
}

// A comma-separated list of subnet IDs.
output "external_subnets" {
  value = ["${aws_subnet.external.*.id}"]
}

// A list of subnet IDs.
output "internal_subnets" {
  value = ["${aws_subnet.internal.*.id}"]
}

// The default VPC security group ID.
output "security_group" {
  value = "${aws_vpc.main.default_security_group_id}"
}

// The list of availability zones of the VPC.
output "availability_zones" {
  value = ["${aws_subnet.external.*.availability_zone}"]
}

// The internal route table ID.
output "internal_rtb_id" {
  value = "${join(",", aws_route_table.internal.*.id)}"
}

// The external route table ID.
output "external_rtb_id" {
  value = "${aws_route_table.external.id}"
}

// The list of EIPs associated with the internal subnets.
output "internal_nat_ips" {
  value = ["${aws_eip.nat.*.public_ip}"]
}
