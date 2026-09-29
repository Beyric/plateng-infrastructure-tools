#!/usr/bin/env bash
# Read-only. Shows, for every private subnet of the cluster, which /28 blocks can
# still be handed to a node as a pod prefix - and what is in the way.
# "Free addresses" in the AWS console is not the number that matters with prefix
# delegation; "free blocks" is. Runbook: projects/weysure/docs/runbooks/VPC_CNI_MODE_CHANGE.md
set -euo pipefail
export AWS_PROFILE=${AWS_PROFILE:-beyric-admin} AWS_REGION=${AWS_REGION:-us-east-1}
CLUSTER=${CLUSTER:-beyric-prod}
aws sts get-caller-identity >/dev/null 2>&1 || { echo "AWS session expired - run: aws sso login --profile $AWS_PROFILE"; exit 1; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
aws ec2 describe-subnets --filters "Name=tag:karpenter.sh/discovery,Values=$CLUSTER" \
  --query 'Subnets[].{id:SubnetId,cidr:CidrBlock,az:AvailabilityZone,free:AvailableIpAddressCount,vpc:VpcId}' --output json > "$W/subnets.json"
VPC=$(python3 -c "import json;print(json.load(open('$W/subnets.json'))[0]['vpc'])")
aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC" \
  --query 'NetworkInterfaces[].{ips:PrivateIpAddresses[].[PrivateIpAddress,Primary],pfx:Ipv4Prefixes[].Ipv4Prefix,d:Description,t:InterfaceType,inst:Attachment.InstanceId}' --output json > "$W/enis.json"
aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC" "Name=instance-state-name,Values=pending,running,stopping,shutting-down" \
  --query 'Reservations[].Instances[].[InstanceId,PrivateDnsName]' --output json > "$W/inst.json"
: > "$W/res.json.tmp"
for s in $(python3 -c "import json;print(' '.join(x['id'] for x in json.load(open('$W/subnets.json'))))"); do
  aws ec2 get-subnet-cidr-reservations --subnet-id "$s" --query 'SubnetIpv4CidrReservations[].[Cidr,ReservationType]' --output json >> "$W/res.json.tmp"; echo >> "$W/res.json.tmp"
done
python3 - "$W" <<'PY'
import json, ipaddress, sys
W = sys.argv[1]
subnets = sorted(json.load(open(W + "/subnets.json")), key=lambda s: s["cidr"])
enis = json.load(open(W + "/enis.json"))
names = {i: (n.split(".")[0] or i) for i, n in json.load(open(W + "/inst.json"))}
reserved = [ipaddress.ip_network(c) for blob in open(W + "/res.json.tmp").read().split("\n\n") if blob.strip() for c, t in json.loads(blob) if t == "prefix"]
worst = 99
for s in subnets:
    net = ipaddress.ip_network(s["cidr"]); base = int(net.network_address); last = int(net.broadcast_address)
    aws_own = {base, base + 1, base + 2, base + 3, last}
    single, prefix = {}, {}
    for e in enis:
        who = names.get(e.get("inst")) or (e.get("d") or e.get("t") or "?")[:40]
        for ip, primary in e["ips"] or []:
            a = ipaddress.ip_address(ip)
            if a in net: single[int(a)] = f"{ip} {who}" + ("" if primary else " (secondary)")
        for p in e["pfx"] or []:
            p = ipaddress.ip_network(p)
            if p.subnet_of(net): prefix[p] = who
    free = 0
    print(f"\n{s['cidr']}  {s['az']}  {s['id']}   free addresses (console): {s['free']}")
    for b in net.subnets(new_prefix=28):
        rng = range(int(b.network_address), int(b.network_address) + 16)
        tag = "reserved" if any(b.subnet_of(r) for r in reserved) else "        "
        held = [single[a] for a in rng if a in single]
        if b in prefix: state = f"in use as a prefix by {prefix[b]}"
        elif any(a in aws_own for a in rng): state = "unusable (contains an address AWS keeps)"
        elif held: state = "BLOCKED by " + "; ".join(held)
        else: state = "FREE"; free += 1
        print(f"  {str(b):18} {tag}  {state}")
    print(f"  => {free} free block(s) = room for {free * 16} more pod addresses; {len(prefix)} in use; {len(single)} single addresses")
    worst = min(worst, free)
print()
if worst == 0: print("RESULT: a subnet has NO free block. A new node there cannot start pods."); sys.exit(2)
if worst < 3:  print(f"RESULT: low - a subnet has only {worst} free block(s). Each new node needs 1-2."); sys.exit(1)
print(f"RESULT: ok - at least {worst} free blocks in every subnet.")
PY
