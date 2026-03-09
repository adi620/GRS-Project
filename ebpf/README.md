# eBPF Tracing Scripts

These scripts monitor kernel networking events using bpftrace.

Scripts:

tcp_retransmissions.bt
    Tracks TCP retransmissions caused by packet loss.

packet_drops.bt
    Counts packet drops in the kernel networking stack.

tcp_receive.bt
    Monitors TCP packets processed by the kernel.

net_queue.bt
    Tracks packets entering the network device queue.

Example usage:

sudo bpftrace ebpf/tcp_retransmissions.bt