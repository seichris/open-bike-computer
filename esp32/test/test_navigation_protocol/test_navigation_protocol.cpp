#if __has_include(<unity.h>)
#include <unity.h>
#else
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define UNITY_BEGIN() 0
#define UNITY_END() 0
#define RUN_TEST(fn) do { fn(); } while (0)
#define TEST_ASSERT_TRUE(value) do { if (!(value)) { fprintf(stderr, "assert true failed at %s:%d\n", __FILE__, __LINE__); exit(1); } } while (0)
#define TEST_ASSERT_FALSE(value) do { if (value) { fprintf(stderr, "assert false failed at %s:%d\n", __FILE__, __LINE__); exit(1); } } while (0)
#define TEST_ASSERT_EQUAL_UINT8(expected, actual) do { if ((expected) != (actual)) { fprintf(stderr, "uint8 mismatch at %s:%d\n", __FILE__, __LINE__); exit(1); } } while (0)
#define TEST_ASSERT_EQUAL_UINT32(expected, actual) do { if ((expected) != (actual)) { fprintf(stderr, "uint32 mismatch at %s:%d\n", __FILE__, __LINE__); exit(1); } } while (0)
#define TEST_ASSERT_EQUAL_STRING(expected, actual) do { if (strcmp((expected), (actual)) != 0) { fprintf(stderr, "string mismatch at %s:%d\n", __FILE__, __LINE__); exit(1); } } while (0)
#define TEST_ASSERT_EQUAL_CHAR(expected, actual) do { if ((expected) != (actual)) { fprintf(stderr, "char mismatch at %s:%d\n", __FILE__, __LINE__); exit(1); } } while (0)
#endif
#include "navigation_payload_queue.h"
#include "navigation_protocol.h"

void test_accepts_valid_payload() {
  NavigationData parsed = {};

  TEST_ASSERT_TRUE(parseNavigationData("2|150|Turn Left onto Main St", &parsed));
  TEST_ASSERT_EQUAL_UINT8(2, parsed.iconID);
  TEST_ASSERT_EQUAL_UINT32(150, parsed.distance);
  TEST_ASSERT_EQUAL_STRING("Turn Left onto Main St", parsed.instruction);
}

void test_rejects_malformed_payloads() {
  NavigationData parsed = {};

  TEST_ASSERT_FALSE(parseNavigationData("", &parsed));
  TEST_ASSERT_FALSE(parseNavigationData("2|150", &parsed));
  TEST_ASSERT_FALSE(parseNavigationData("2|150|Turn|Extra", &parsed));
  TEST_ASSERT_FALSE(parseNavigationData("-1|150|Turn", &parsed));
  TEST_ASSERT_FALSE(parseNavigationData("2|-150|Turn", &parsed));
  TEST_ASSERT_FALSE(parseNavigationData("2|abc|Turn", &parsed));
  TEST_ASSERT_FALSE(parseNavigationData("2|150|", &parsed));
}

void test_rejects_invalid_icons() {
  NavigationData parsed = {};

  TEST_ASSERT_FALSE(parseNavigationData("0|150|Continue", &parsed));
  TEST_ASSERT_FALSE(parseNavigationData("5|150|Continue", &parsed));
  TEST_ASSERT_FALSE(parseNavigationData("256|150|Continue", &parsed));
  TEST_ASSERT_TRUE(isValidNavigationIcon(1));
  TEST_ASSERT_TRUE(isValidNavigationIcon(4));
  TEST_ASSERT_FALSE(isValidNavigationIcon(0));
  TEST_ASSERT_FALSE(isValidNavigationIcon(5));
}

void test_distance_supports_uint32_and_rejects_overflow() {
  NavigationData parsed = {};

  TEST_ASSERT_TRUE(parseNavigationData("1|4294967295|Continue", &parsed));
  TEST_ASSERT_EQUAL_UINT32(UINT32_MAX, parsed.distance);
  TEST_ASSERT_FALSE(parseNavigationData("1|4294967296|Continue", &parsed));
}

void test_instruction_is_truncated_to_display_contract() {
  NavigationData parsed = {};
  const char *payload = "1|42|abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789++++";

  TEST_ASSERT_TRUE(parseNavigationData(payload, &parsed));
  TEST_ASSERT_EQUAL_UINT32(NAV_INSTRUCTION_MAX_LEN, strlen(parsed.instruction));
  TEST_ASSERT_EQUAL_CHAR('\0', parsed.instruction[NAV_INSTRUCTION_MAX_LEN]);
}

void test_payload_queue_replaces_pending_payload() {
  NavigationPayloadQueue queue;
  char payload[NAV_PAYLOAD_MAX_LEN + 1] = {};

  TEST_ASSERT_FALSE(queue.hasPending());
  TEST_ASSERT_TRUE(queue.enqueue("1|10|Continue"));
  TEST_ASSERT_TRUE(queue.enqueue("2|20|Turn Left"));
  TEST_ASSERT_TRUE(queue.hasPending());
  TEST_ASSERT_TRUE(queue.dequeue(payload, sizeof(payload)));
  TEST_ASSERT_EQUAL_STRING("2|20|Turn Left", payload);
  TEST_ASSERT_FALSE(queue.hasPending());
  TEST_ASSERT_FALSE(queue.dequeue(payload, sizeof(payload)));
}

void test_payload_queue_rejects_empty_and_oversized_payloads() {
  NavigationPayloadQueue queue;
  std::string oversized(NAV_PAYLOAD_MAX_LEN + 1, 'x');
  char payload[NAV_PAYLOAD_MAX_LEN + 1] = {};

  TEST_ASSERT_FALSE(queue.enqueue(""));
  TEST_ASSERT_FALSE(queue.enqueue(oversized));
  TEST_ASSERT_FALSE(queue.dequeue(payload, sizeof(payload)));
}

int main() {
  UNITY_BEGIN();
  RUN_TEST(test_accepts_valid_payload);
  RUN_TEST(test_rejects_malformed_payloads);
  RUN_TEST(test_rejects_invalid_icons);
  RUN_TEST(test_distance_supports_uint32_and_rejects_overflow);
  RUN_TEST(test_instruction_is_truncated_to_display_contract);
  RUN_TEST(test_payload_queue_replaces_pending_payload);
  RUN_TEST(test_payload_queue_rejects_empty_and_oversized_payloads);
  return UNITY_END();
}
