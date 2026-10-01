/*
 * AutoProtect subsystem tests
 *
 * Copyright (c) 2026 QEMU contributors
 *
 * This work is licensed under the terms of the GNU GPL, version 2 or later.
 * See the COPYING file in the top-level directory.
 */

#include "qemu/osdep.h"
#include "libqtest.h"
#include "qobject/qdict.h"
#include "qobject/qstring.h"

static void test_autoprotect_status_initial(void)
{
    QTestState *qts = qtest_init("-nodefaults -machine none");
    QDict *resp = qtest_qmp(qts, "{ 'execute': 'autoprotect-status' }");
    g_assert_nonnull(resp);
    QDict *ret = qdict_get_qdict(resp, "return");
    g_assert_nonnull(ret);
    g_assert_false(qdict_get_bool(ret, "enabled"));
    g_assert_cmpint(qdict_get_int(ret, "snapshots-taken"), ==, 0);
    g_assert_cmpint(qdict_get_int(ret, "snapshots-pruned"), ==, 0);
    qobject_unref(resp);
    qtest_quit(qts);
}

static void test_autoprotect_invalid_args(void)
{
    QTestState *qts = qtest_init("-nodefaults -machine none");
    QDict *resp;

    /* Test non-positive interval */
    resp = qtest_qmp(qts, "{ 'execute': 'autoprotect-enable', 'arguments': { "
                          "'interval-seconds': 0, 'retention-hours': 1 } }");
    qmp_expect_error_and_unref(resp, "GenericError");

    resp = qtest_qmp(qts, "{ 'execute': 'autoprotect-enable', 'arguments': { "
                          "'interval-seconds': -10, 'retention-hours': 1 } }");
    qmp_expect_error_and_unref(resp, "GenericError");

    /* Test non-positive retention */
    resp = qtest_qmp(qts, "{ 'execute': 'autoprotect-enable', 'arguments': { "
                          "'interval-seconds': 60, 'retention-hours': 0 } }");
    qmp_expect_error_and_unref(resp, "GenericError");

    resp = qtest_qmp(qts, "{ 'execute': 'autoprotect-enable', 'arguments': { "
                          "'interval-seconds': 60, 'retention-hours': -5 } }");
    qmp_expect_error_and_unref(resp, "GenericError");

    qtest_quit(qts);
}

static void test_autoprotect_enable_disable(void)
{
    QTestState *qts = qtest_init("-nodefaults -machine none");
    QDict *resp;
    QDict *ret;

    /* Enable with valid config */
    resp = qtest_qmp(qts, "{ 'execute': 'autoprotect-enable', 'arguments': { "
                          "'interval-seconds': 300, 'retention-hours': 12, "
                          "'name-prefix': 'mytest-', 'mode': 'internal' } }");
    g_assert_nonnull(resp);
    g_assert(qdict_haskey(resp, "return"));
    qobject_unref(resp);

    /* Check status reflects enabled config */
    resp = qtest_qmp(qts, "{ 'execute': 'autoprotect-status' }");
    g_assert_nonnull(resp);
    ret = qdict_get_qdict(resp, "return");
    g_assert_nonnull(ret);
    g_assert_true(qdict_get_bool(ret, "enabled"));
    g_assert_cmpstr(qdict_get_str(ret, "active-mode"), ==, "internal");

    QDict *cfg = qdict_get_qdict(ret, "config");
    g_assert_nonnull(cfg);
    g_assert_cmpint(qdict_get_int(cfg, "interval-seconds"), ==, 300);
    g_assert_cmpint(qdict_get_int(cfg, "retention-hours"), ==, 12);
    g_assert_cmpstr(qdict_get_str(cfg, "name-prefix"), ==, "mytest-");
    qobject_unref(resp);

    /* Disable */
    resp = qtest_qmp(qts, "{ 'execute': 'autoprotect-disable' }");
    g_assert_nonnull(resp);
    g_assert(qdict_haskey(resp, "return"));
    qobject_unref(resp);

    /* Verify disabled status */
    resp = qtest_qmp(qts, "{ 'execute': 'autoprotect-status' }");
    g_assert_nonnull(resp);
    ret = qdict_get_qdict(resp, "return");
    g_assert_nonnull(ret);
    g_assert_false(qdict_get_bool(ret, "enabled"));
    qobject_unref(resp);

    qtest_quit(qts);
}

static void test_autoprotect_hmp(void)
{
    QTestState *qts = qtest_init("-nodefaults -machine none");
    QDict *resp;
    const char *out;

    /* Test HMP info autoprotect when disabled */
    resp = qtest_qmp(qts, "{ 'execute': 'human-monitor-command', "
                          "'arguments': { 'command-line': 'info autoprotect' } }");
    g_assert_nonnull(resp);
    out = qdict_get_str(resp, "return");
    g_assert_nonnull(strstr(out, "AutoProtect: disabled"));
    qobject_unref(resp);

    /* Test HMP autoprotect on */
    resp = qtest_qmp(qts, "{ 'execute': 'human-monitor-command', "
                          "'arguments': { 'command-line': 'autoprotect on 60 4 internal testprefix-' } }");
    g_assert_nonnull(resp);
    qobject_unref(resp);

    /* Test HMP info autoprotect when enabled */
    resp = qtest_qmp(qts, "{ 'execute': 'human-monitor-command', "
                          "'arguments': { 'command-line': 'info autoprotect' } }");
    g_assert_nonnull(resp);
    out = qdict_get_str(resp, "return");
    g_assert_nonnull(strstr(out, "AutoProtect: enabled"));
    g_assert_nonnull(strstr(out, "Active Mode:   internal"));
    g_assert_nonnull(strstr(out, "Prefix:        testprefix-"));
    qobject_unref(resp);

    /* Test HMP autoprotect off */
    resp = qtest_qmp(qts, "{ 'execute': 'human-monitor-command', "
                          "'arguments': { 'command-line': 'autoprotect off' } }");
    g_assert_nonnull(resp);
    qobject_unref(resp);

    /* Verify disabled again */
    resp = qtest_qmp(qts, "{ 'execute': 'human-monitor-command', "
                          "'arguments': { 'command-line': 'info autoprotect' } }");
    g_assert_nonnull(resp);
    out = qdict_get_str(resp, "return");
    g_assert_nonnull(strstr(out, "AutoProtect: disabled"));
    qobject_unref(resp);

    qtest_quit(qts);
}

static void test_autoprotect_cmdline(void)
{
    QTestState *qts = qtest_init("-nodefaults -machine none "
                                 "-autoprotect interval=120,retention=6,mode=internal,prefix=bootpref-");
    QDict *resp = qtest_qmp(qts, "{ 'execute': 'autoprotect-status' }");
    g_assert_nonnull(resp);
    QDict *ret = qdict_get_qdict(resp, "return");
    g_assert_nonnull(ret);
    g_assert_true(qdict_get_bool(ret, "enabled"));
    g_assert_cmpstr(qdict_get_str(ret, "active-mode"), ==, "internal");

    QDict *cfg = qdict_get_qdict(ret, "config");
    g_assert_nonnull(cfg);
    g_assert_cmpint(qdict_get_int(cfg, "interval-seconds"), ==, 120);
    g_assert_cmpint(qdict_get_int(cfg, "retention-hours"), ==, 6);
    g_assert_cmpstr(qdict_get_str(cfg, "name-prefix"), ==, "bootpref-");

    qobject_unref(resp);
    qtest_quit(qts);
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);

    qtest_add_func("/autoprotect/status_initial", test_autoprotect_status_initial);
    qtest_add_func("/autoprotect/invalid_args", test_autoprotect_invalid_args);
    qtest_add_func("/autoprotect/enable_disable", test_autoprotect_enable_disable);
    qtest_add_func("/autoprotect/hmp", test_autoprotect_hmp);
    qtest_add_func("/autoprotect/cmdline", test_autoprotect_cmdline);

    return g_test_run();
}
