#import "DnsResolver.h"

#include <arpa/inet.h>
#include <resolv.h>

NSArray<NSString *> *DNSServers(void) {
  res_state res = malloc(sizeof(*res));
  if (!res) {
    return @[];
  }
  if (res_ninit(res) != 0) {
    free(res);
    return @[];
  }

  union res_sockaddr_union addrs[MAXNS];
  int count = res_getservers(res, addrs, MAXNS);
  NSMutableArray<NSString *> *servers = [NSMutableArray array];

  for (int i = 0; i < count; i++) {
    char buf[INET6_ADDRSTRLEN];
    memset(buf, 0, sizeof(buf));
    if (addrs[i].sin.sin_family == AF_INET) {
      if (inet_ntop(AF_INET, &addrs[i].sin.sin_addr, buf, sizeof(buf)) != NULL) {
        [servers addObject:[NSString stringWithUTF8String:buf]];
      }
    } else if (addrs[i].sin6.sin6_family == AF_INET6) {
      if (inet_ntop(AF_INET6, &addrs[i].sin6.sin6_addr, buf, sizeof(buf)) != NULL) {
        [servers addObject:[NSString stringWithUTF8String:buf]];
      }
    }
  }

  res_ndestroy(res);
  free(res);
  return servers;
}
