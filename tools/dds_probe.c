/*
 * Standalone CycloneDDS discovery probe.
 *
 * Enumerates all remote DDS participants, publications (writers) and
 * subscriptions (readers) on domain 0 by reading the built-in topics
 * DCPSParticipant, DCPSPublication, DCPSSubscription.
 *
 * Build:
 *   gcc -Wall -O2 -o dds_probe dds_probe.c -I/usr/local/include \
 *       -L/usr/local/lib -Wl,-rpath,/usr/local/lib -lddsc
 *
 * Run:
 *   CYCLONEDDS_URI=file://$PWD/probe_cyclonedds.xml ./dds_probe
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <inttypes.h>

#include "dds/dds.h"

static volatile sig_atomic_t g_stop = 0;
static void on_sigint(int s) { (void)s; g_stop = 1; }

#define MAX_SAMPLES 128

static void guid_to_hex(const dds_guid_t *g, char out[33])
{
    static const char *hex = "0123456789abcdef";
    for (int i = 0; i < 16; i++) {
        out[i*2]   = hex[(g->v[i] >> 4) & 0xF];
        out[i*2+1] = hex[g->v[i] & 0xF];
    }
    out[32] = 0;
}

static void poll_participants(dds_entity_t rd)
{
    void *samples[MAX_SAMPLES] = {0};
    dds_sample_info_t infos[MAX_SAMPLES];
    for (int i = 0; i < MAX_SAMPLES; i++) samples[i] = NULL;

    dds_return_t n = dds_take(rd, samples, infos, MAX_SAMPLES, MAX_SAMPLES);
    if (n <= 0) return;
    for (int i = 0; i < n; i++) {
        if (!infos[i].valid_data) continue;
        dds_builtintopic_participant_t *p = (dds_builtintopic_participant_t *)samples[i];
        char guid[33];
        guid_to_hex(&p->key, guid);
        printf("[PARTICIPANT] guid=%s\n", guid);
    }
    dds_return_loan(rd, samples, n);
}

static void poll_endpoints(dds_entity_t rd, const char *kind)
{
    void *samples[MAX_SAMPLES] = {0};
    dds_sample_info_t infos[MAX_SAMPLES];
    for (int i = 0; i < MAX_SAMPLES; i++) samples[i] = NULL;

    dds_return_t n = dds_take(rd, samples, infos, MAX_SAMPLES, MAX_SAMPLES);
    if (n <= 0) return;
    for (int i = 0; i < n; i++) {
        if (!infos[i].valid_data) continue;
        dds_builtintopic_endpoint_t *e = (dds_builtintopic_endpoint_t *)samples[i];
        char guid[33], pguid[33];
        guid_to_hex(&e->key, guid);
        guid_to_hex(&e->participant_key, pguid);
        printf("[%s] topic=%-40s type=%-45s participant=%s guid=%s\n",
               kind,
               e->topic_name ? e->topic_name : "(null)",
               e->type_name  ? e->type_name  : "(null)",
               pguid, guid);
    }
    dds_return_loan(rd, samples, n);
}

int main(int argc, char **argv)
{
    int seconds = 20;
    if (argc >= 2) seconds = atoi(argv[1]);

    signal(SIGINT, on_sigint);

    printf("== CycloneDDS probe: domain 0, listening %d seconds ==\n", seconds);
    fflush(stdout);

    dds_entity_t dp = dds_create_participant(0, NULL, NULL);
    if (dp < 0) {
        fprintf(stderr, "dds_create_participant failed: %s\n", dds_strretcode(-dp));
        return 1;
    }

    dds_entity_t rd_part = dds_create_reader(dp, DDS_BUILTIN_TOPIC_DCPSPARTICIPANT,  NULL, NULL);
    dds_entity_t rd_pub  = dds_create_reader(dp, DDS_BUILTIN_TOPIC_DCPSPUBLICATION,  NULL, NULL);
    dds_entity_t rd_sub  = dds_create_reader(dp, DDS_BUILTIN_TOPIC_DCPSSUBSCRIPTION, NULL, NULL);

    if (rd_part < 0 || rd_pub < 0 || rd_sub < 0) {
        fprintf(stderr, "failed to create builtin readers: p=%d w=%d r=%d\n",
                (int)rd_part, (int)rd_pub, (int)rd_sub);
        return 2;
    }

    for (int t = 0; t < seconds && !g_stop; t++) {
        poll_participants(rd_part);
        poll_endpoints(rd_pub, "WRITER");
        poll_endpoints(rd_sub, "READER");
        fflush(stdout);
        sleep(1);
    }

    printf("== probe finished ==\n");
    dds_delete(dp);
    return 0;
}
