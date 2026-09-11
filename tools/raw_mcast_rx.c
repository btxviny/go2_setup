/*
 * Bare-metal multicast UDP receiver — no DDS at all.
 * Binds UDP :<port> on INADDR_ANY, joins <group> on interface <ifname>,
 * prints one line per received datagram.
 *
 * Usage: ./raw_mcast_rx enp7s0 239.255.0.1 7400
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <net/if.h>
#include <netinet/in.h>

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s <ifname> <group> <port>\n", argv[0]);
        return 1;
    }
    const char *ifname = argv[1];
    const char *group  = argv[2];
    int         port   = atoi(argv[3]);

    int s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s < 0) { perror("socket"); return 2; }

    int on = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &on, sizeof(on));

    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    a.sin_port = htons(port);
    if (bind(s, (struct sockaddr *)&a, sizeof(a)) < 0) {
        perror("bind"); return 3;
    }

    struct ip_mreqn mreq = {0};
    mreq.imr_multiaddr.s_addr = inet_addr(group);
    mreq.imr_address.s_addr   = htonl(INADDR_ANY);
    mreq.imr_ifindex          = if_nametoindex(ifname);
    if (mreq.imr_ifindex == 0) {
        fprintf(stderr, "if_nametoindex(%s) failed: %s\n", ifname, strerror(errno));
        return 4;
    }
    if (setsockopt(s, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, sizeof(mreq)) < 0) {
        perror("IP_ADD_MEMBERSHIP"); return 5;
    }

    fprintf(stderr, "listening on %s:%d joined %s on ifindex=%d (%s)\n",
            "0.0.0.0", port, group, mreq.imr_ifindex, ifname);

    char buf[65536];
    struct sockaddr_in src;
    socklen_t sl = sizeof(src);
    int count = 0;
    while (1) {
        ssize_t n = recvfrom(s, buf, sizeof(buf), 0, (struct sockaddr *)&src, &sl);
        if (n < 0) { perror("recvfrom"); return 6; }
        char sip[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &src.sin_addr, sip, sizeof(sip));
        printf("[%04d] %zd bytes from %s:%d\n", ++count, n, sip, ntohs(src.sin_port));
        fflush(stdout);
    }
    return 0;
}
