#include "mremote/rdp_bridge.h"
#include "mremote/rdp_bridge_mock.h"

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

/* The ABI 7 surface: a SOCKS5 proxy - its config rules, and what reaches the
 * backend. Run against the mock backend. */

typedef struct abi7_context {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    mr_rdp_session *session;
    int config_seen;
    char proxy_hostname[256];
    int proxy_hostname_present;
    uint16_t proxy_port;
} abi7_context;

#define REQUIRE(condition) \
    do { \
        if (!(condition)) { \
            (void)fprintf(stderr, "%s:%d: requirement failed: %s\n", \
                          __FILE__, __LINE__, #condition); \
            return 0; \
        } \
    } while (0)

static void observe_connection(void *opaque, const mr_rdp_mock_connection_config *config)
{
    abi7_context *context = (abi7_context *)opaque;
    (void)pthread_mutex_lock(&context->mutex);
    ++context->config_seen;
    context->proxy_hostname_present = config->proxy_hostname != NULL;
    (void)snprintf(context->proxy_hostname, sizeof(context->proxy_hostname), "%s",
                   config->proxy_hostname != NULL ? config->proxy_hostname : "");
    context->proxy_port = config->proxy_port;
    (void)pthread_cond_broadcast(&context->condition);
    (void)pthread_mutex_unlock(&context->mutex);
}

static int wait_for_config(abi7_context *context)
{
    struct timespec deadline;
    int ok = 1;
    (void)clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 3;
    (void)pthread_mutex_lock(&context->mutex);
    while (context->config_seen == 0 && ok) {
        ok = pthread_cond_timedwait(&context->condition, &context->mutex, &deadline) == 0;
    }
    (void)pthread_mutex_unlock(&context->mutex);
    return ok;
}

static void *run_thread(void *opaque)
{
    abi7_context *context = (abi7_context *)opaque;
    (void)mr_rdp_session_run(context->session);
    return NULL;
}

static void initialize_config(mr_rdp_config *config, uint64_t generation)
{
    static const char hostname[] = "abi7.example.test";
    static const char username[] = "user";
    static const char password[] = "password";
    mr_rdp_config_init(config);
    config->generation = generation;
    config->hostname = hostname;
    config->username = username;
    config->username_length = sizeof(username) - 1u;
    config->password = password;
    config->password_length = sizeof(password) - 1u;
}

static int created(mr_rdp_config *config)
{
    mr_rdp_session *session = NULL;
    if (mr_rdp_session_create_mock(config, NULL, NULL, NULL, &session) != MR_RDP_STATUS_OK) {
        return 0;
    }
    return mr_rdp_session_destroy(session) == MR_RDP_STATUS_OK;
}

static int test_config_validation(void)
{
    static const char proxy[] = "proxy.example.test";
    static const char user[] = "proxy-user";
    char long_name[300];
    mr_rdp_config config;
    initialize_config(&config, 1u);
    REQUIRE(config.abi_version == MR_RDP_BRIDGE_ABI_VERSION && MR_RDP_BRIDGE_ABI_VERSION >= 7u);
    REQUIRE(config.proxy_type == MR_RDP_PROXY_NONE && config.proxy_hostname == NULL &&
            config.proxy_port == 0u && config.reserved_abi7 == 0u);
    REQUIRE(created(&config));
    /* A hostname or port without the type. */
    config.proxy_hostname = proxy;
    REQUIRE(!created(&config));
    config.proxy_hostname = NULL;
    config.proxy_port = 1080u;
    REQUIRE(!created(&config));
    /* The type without a hostname. */
    config.proxy_type = MR_RDP_PROXY_SOCKS5;
    REQUIRE(!created(&config));
    config.proxy_hostname = proxy;
    REQUIRE(created(&config));
    config.proxy_port = 0u;
    REQUIRE(created(&config));
    /* A sign-in is reserved. */
    config.proxy_username = user;
    config.proxy_username_length = sizeof(user) - 1u;
    REQUIRE(!created(&config));
    config.proxy_username = NULL;
    config.proxy_username_length = 0u;
    config.proxy_password_length = 1u;
    REQUIRE(!created(&config));
    config.proxy_password_length = 0u;
    config.reserved_abi7 = 1u;
    REQUIRE(!created(&config));
    config.reserved_abi7 = 0u;
    config.proxy_type = 2u;
    REQUIRE(!created(&config));
    config.proxy_type = MR_RDP_PROXY_SOCKS5;
    memset(long_name, 'a', sizeof(long_name) - 1u);
    long_name[sizeof(long_name) - 1u] = '\0';
    config.proxy_hostname = long_name;
    REQUIRE(!created(&config));
    config.proxy_hostname = "";
    REQUIRE(!created(&config));
    return 1;
}

static int run_with(mr_rdp_config *config, abi7_context *context)
{
    mr_rdp_mock_script script;
    pthread_t thread;
    memset(context, 0, sizeof(*context));
    REQUIRE(pthread_mutex_init(&context->mutex, NULL) == 0);
    REQUIRE(pthread_cond_init(&context->condition, NULL) == 0);
    mr_rdp_mock_script_init(&script);
    script.on_connection_config = observe_connection;
    script.observer_context = context;
    REQUIRE(mr_rdp_session_create_mock(config, NULL, context, &script, &context->session) ==
            MR_RDP_STATUS_OK);
    REQUIRE(pthread_create(&thread, NULL, run_thread, context) == 0);
    REQUIRE(wait_for_config(context));
    REQUIRE(mr_rdp_session_request_stop(context->session) == MR_RDP_STATUS_OK);
    REQUIRE(pthread_join(thread, NULL) == 0);
    REQUIRE(mr_rdp_session_destroy(context->session) == MR_RDP_STATUS_OK);
    (void)pthread_cond_destroy(&context->condition);
    (void)pthread_mutex_destroy(&context->mutex);
    return 1;
}

static int test_the_backend_gets_the_proxy(void)
{
    char proxy[] = "proxy.example.test";
    mr_rdp_config config;
    abi7_context context;

    initialize_config(&config, 2u);
    config.proxy_type = MR_RDP_PROXY_SOCKS5;
    config.proxy_hostname = proxy;
    config.proxy_port = 9050u;
    REQUIRE(run_with(&config, &context));
    REQUIRE(context.proxy_hostname_present);
    REQUIRE(strcmp(context.proxy_hostname, "proxy.example.test") == 0);
    REQUIRE(context.proxy_port == 9050u);

    /* Port zero is the SOCKS default; and the hostname was copied. */
    config.generation = 3u;
    config.proxy_port = 0u;
    REQUIRE(run_with(&config, &context));
    REQUIRE(context.proxy_port == MR_RDP_DEFAULT_PROXY_PORT);

    /* Without one, nothing. */
    initialize_config(&config, 4u);
    REQUIRE(run_with(&config, &context));
    REQUIRE(!context.proxy_hostname_present && context.proxy_port == 0u);
    return 1;
}

int main(void)
{
    int ok = 1;
    ok &= test_config_validation();
    ok &= test_the_backend_gets_the_proxy();
    if (!ok) {
        return 1;
    }
    (void)puts("abi7 contract tests passed");
    return 0;
}
