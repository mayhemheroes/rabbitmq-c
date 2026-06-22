/* oracle_parse_url.c — behavioral oracle for the rabbitmq-c test.sh PATCH gate.
 *
 * Parses a known AMQP URL and PRINTS the decoded fields to stdout so that
 * test.sh can grep for expected values.  A neutered binary (LD_PRELOAD exit(0))
 * produces NO output, causing the grep to fail — this is the anti-reward-hacking
 * property required by SPEC §6.3.
 *
 * Build (inside the container, with the static library available):
 *   $CC $SANITIZER_FLAGS $DEBUG_FLAGS \
 *       -I$BUILD/include -I$SRC/include -I$BUILD/librabbitmq \
 *       -DHAVE_CONFIG_H -DAMQP_STATIC \
 *       mayhem/harnesses/oracle_parse_url.c $LIBA -lpthread \
 *       -o /mayhem/oracle_parse_url
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <rabbitmq-c/amqp.h>

static void check(const char *label, const char *got, const char *expected) {
  if (strcmp(got, expected) != 0) {
    fprintf(stderr, "FAIL %s: expected '%s', got '%s'\n", label, expected, got);
    exit(1);
  }
}

static void check_int(const char *label, int got, int expected) {
  if (got != expected) {
    fprintf(stderr, "FAIL %s: expected %d, got %d\n", label, expected, got);
    exit(1);
  }
}

int main(void) {
  /* Test 1: plain amqp URI with explicit credentials, host, port, vhost */
  {
    char url[] = "amqp://myuser:mypass@broker.example.com:5673/myvhost";
    struct amqp_connection_info ci;
    amqp_default_connection_info(&ci);
    int rc = amqp_parse_url(url, &ci);
    if (rc != AMQP_STATUS_OK) {
      fprintf(stderr, "FAIL parse_url returned %d: %s\n", rc,
              amqp_error_string2(rc));
      return 1;
    }
    /* Print fields so test.sh can grep for known answers. */
    printf("parse_url user=%s\n", ci.user ? ci.user : "(null)");
    printf("parse_url password=%s\n", ci.password ? ci.password : "(null)");
    printf("parse_url host=%s\n", ci.host ? ci.host : "(null)");
    printf("parse_url port=%d\n", ci.port);
    printf("parse_url vhost=%s\n", ci.vhost ? ci.vhost : "(null)");

    check("user",     ci.user,     "myuser");
    check("password", ci.password, "mypass");
    check("host",     ci.host,     "broker.example.com");
    check_int("port", ci.port,     5673);
    check("vhost",    ci.vhost,    "myvhost");
  }

  /* Test 2: minimal URI — defaults for port (5672) and vhost (/) */
  {
    char url[] = "amqp://localhost";
    struct amqp_connection_info ci;
    amqp_default_connection_info(&ci);
    int rc = amqp_parse_url(url, &ci);
    if (rc != AMQP_STATUS_OK) {
      fprintf(stderr, "FAIL minimal parse_url returned %d\n", rc);
      return 1;
    }
    printf("default port=%d\n", ci.port);
    printf("default vhost=%s\n", ci.vhost ? ci.vhost : "(null)");

    check_int("default port", ci.port, 5672);
    check("default vhost", ci.vhost, "/");
  }

  /* Test 3: invalid URI must return an error code (not AMQP_STATUS_OK) */
  {
    char bad[] = "not-a-url";
    struct amqp_connection_info ci;
    amqp_default_connection_info(&ci);
    int rc = amqp_parse_url(bad, &ci);
    printf("bad_url_rc=%d\n", rc);
    if (rc == AMQP_STATUS_OK) {
      fprintf(stderr, "FAIL bad URL was accepted: %s\n", bad);
      return 1;
    }
  }

  printf("oracle_parse_url: ALL PASS\n");
  return 0;
}
