/*
# Copyright (c) 2019 Cable Television Laboratories, Inc.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
*/
/* -*- P4_16 -*- */
#include <tna.p4>

/* TPS includes */
#include "../include/tps_consts.p4"
#include "../include/tps_headers.p4"
#include "../include/tps_checksum.p4"
#include "../include/tofino_util.p4"

/*************************************************************************
****************** Aggregate TPS P A R S E R  ****************************
*************************************************************************/
parser TpsAggParser(packet_in packet,
                    out headers hdr,
                    out metadata ig_meta,
                    out ingress_intrinsic_metadata_t ig_intr_md) {

    TofinoIngressParser() tofino_parser;

    state start {
        tofino_parser.apply(packet, ig_intr_md);
        transition parse_ethernet;
    }

    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            TYPE_ARP: parse_arp;
            TYPE_IPV4: parse_ipv4;
            TYPE_IPV6: parse_ipv6;
            default: accept;
        }
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            TYPE_UDP: parse_udp;
            TYPE_TCP: parse_tcp;
            default: accept;
        }
    }

    state parse_ipv6 {
        packet.extract(hdr.ipv6);
        transition select(hdr.ipv6.next_hdr_proto) {
            TYPE_UDP: parse_udp;
            TYPE_TCP: parse_tcp;
            default: accept;
        }
    }

    state parse_udp {
        packet.extract(hdr.udp);
        transition select(hdr.udp.dst_port) {
            UDP_INT_DST_PORT: parse_int_shim;
            default: accept;
        }
    }

    state parse_int_shim {
        packet.extract(hdr.int_shim);
        transition parse_int_hdr;
    }

    state parse_int_hdr {
        packet.extract(hdr.int_header);
        transition accept;
    }

    state parse_tcp {
        packet.extract(hdr.tcp);
        transition accept;
    }

    state parse_arp {
        packet.extract(hdr.arp);
        transition accept;
    }
}

/*************************************************************************
**************  I N G R E S S   P R O C E S S I N G   ********************
*************************************************************************/

control TpsAggIngress(inout headers hdr,
                      inout metadata meta,
                      in ingress_intrinsic_metadata_t ig_intr_md,
                      in ingress_intrinsic_metadata_from_parser_t ig_prsr_md,
                      inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
                      inout ingress_intrinsic_metadata_for_tm_t ig_tm_md) {


    /* counter(MAX_DEVICE_ID, CounterType.packets_and_bytes) forwardedPackets; */

    action data_forward(PortId_t port) {
        ig_tm_md.ucast_egress_port = port;
    }

    table data_forward_t {
        key = {
            hdr.ethernet.dst_mac: exact;
        }
        actions = {
            data_forward;
            NoAction;
        }
        size = TABLE_SIZE;
        default_action = NoAction();
    }

    action add_switch_id(bit<32> switch_id) {
        hdr.int_meta_2.setValid();
        #ifdef BMV2
        hdr.ipv4.totalLen = hdr.ipv4.totalLen + BYTES_PER_SHIM * INT_SHIM_HOP_SIZE;
        hdr.udp.len = hdr.udp.len + BYTES_PER_SHIM * INT_SHIM_HOP_SIZE;
        hdr.ipv6.payload_len = hdr.ipv6.payload_len + BYTES_PER_SHIM * INT_SHIM_HOP_SIZE;
        hdr.int_shim.length = hdr.int_shim.length + INT_SHIM_HOP_SIZE;
        hdr.int_header.remaining_hop_cnt = hdr.int_header.remaining_hop_cnt - 1;
        #endif

        hdr.int_meta_2.switch_id = switch_id;
    }

    table add_switch_id_t {
        key = {
            hdr.udp.dst_port: exact;
        }
        actions = {
            add_switch_id;
            NoAction;
        }
        size = TABLE_SIZE;
        default_action = NoAction();
    }

    action data_inspect_packet(bit<32> device, bit<32> switch_id) {
        hdr.int_shim.setValid();
        hdr.int_header.setValid();
        hdr.int_meta.setValid();

        hdr.int_shim.npt = INT_SHIM_NPT_UDP_FULL_WRAP;
        hdr.int_shim.type = INT_SHIM_TYPE;
        hdr.int_shim.length = INT_SHIM_BASE_SIZE;

        hdr.int_header.ver = INT_VERSION;
        hdr.int_header.domain_id = INT_SHIM_DOMAIN_ID;
        hdr.int_header.meta_len = INT_META_LEN;
        hdr.int_header.instr_bit_0 = TRUE;
        hdr.int_header.ds_instr_0 = TRUE;
        hdr.int_header.ds_flags_1 = TRUE;
        hdr.int_header.remaining_hop_cnt = MAX_HOPS;

        hdr.int_meta.switch_id = switch_id;
        hdr.int_meta.orig_mac = hdr.ethernet.src_mac;

        #ifdef BMV2
        forwardedPackets.count(device);
        #endif
    }

    action data_inspect_packet_ipv4() {
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
        hdr.ipv4.protocol = TYPE_UDP;
        hdr.int_shim.next_proto = hdr.ipv4.protocol;

        #ifdef BMV2
        hdr.ipv4.totalLen = hdr.ipv4.totalLen + ((bit<16>)hdr.int_shim.length * BYTES_PER_SHIM * INT_SHIM_HOP_SIZE) + UDP_HDR_BYTES;
        #endif
    }

    action data_inspect_packet_ipv6() {
        hdr.ipv6.next_hdr_proto = TYPE_UDP;
        hdr.int_shim.next_proto = hdr.ipv6.next_hdr_proto;
        #ifdef BMV2
        hdr.ipv6.payload_len = hdr.ipv6.payload_len + IPV6_HDR_BYTES + ((bit<16>)hdr.int_shim.length * BYTES_PER_SHIM * INT_SHIM_HOP_SIZE) + UDP_HDR_BYTES;
        #endif
    }

    table data_inspection_t {
        key = {
            hdr.ethernet.src_mac: exact;
        }
        actions = {
            data_inspect_packet;
            NoAction;
        }
        size = TABLE_SIZE;
        default_action = NoAction();
    }

    action insert_udp_int_for_udp() {
        hdr.udp_int.setValid();
        hdr.udp_int.dst_port = hdr.udp.dst_port;
        hdr.udp_int.src_port = hdr.udp.src_port;
        hdr.udp_int.len = hdr.udp.len;
        hdr.udp_int.cksum = hdr.udp.cksum;

        hdr.udp.src_port = UDP_INT_SRC_PORT;
        hdr.udp.dst_port = UDP_INT_DST_PORT;

        #ifdef BMV2
        hdr.udp.len = hdr.udp_int.len + ((bit<16>)hdr.int_shim.length * BYTES_PER_SHIM * INT_SHIM_HOP_SIZE) + UDP_HDR_BYTES;
        #endif
    }

    action insert_udp_int_for_tcp_ipv4() {
        hdr.udp.setValid();
        hdr.udp.src_port = UDP_INT_SRC_PORT;
        hdr.udp.dst_port = UDP_INT_DST_PORT;

        #ifdef BMV2
        hdr.udp.len = hdr.ipv4.totalLen - IPV4_HDR_BYTES;
        #endif
    }

    action insert_udp_int_for_tcp_ipv6() {
       hdr.udp.setValid();
       hdr.udp.src_port = UDP_INT_SRC_PORT;
       hdr.udp.dst_port = UDP_INT_DST_PORT;

       #ifdef BMV2
       hdr.udp.len = hdr.ipv6.payload_len - IPV6_HDR_BYTES;
       #endif
    }

    /*
    action generate_learn_notification() {
        digest<mac_learn_digest>((bit<32>) 1024,
            { hdr.arp.src_mac,
              standard_metadata.ingress_port
            });
    }
    */

    /*
    action arp_flood() {
        standard_metadata.mcast_grp = 1;
    }

    table arp_flood_t {
        key = {
            hdr.ethernet.dst_mac: exact;
        }
        actions = {
            arp_flood;
            NoAction;
        }
        default_action = NoAction();
    }

    */
     apply {
        if (hdr.int_shim.isValid()) {
            add_switch_id_t.apply();
        }
        else {
            data_inspection_t.apply();
            if (hdr.int_shim.isValid()) {
                if (hdr.ipv4.isValid()) {
                    data_inspect_packet_ipv4();
                    if (hdr.udp.isValid()) {
                        insert_udp_int_for_udp();
                    } else if (hdr.tcp.isValid()) {
                        insert_udp_int_for_tcp_ipv4();
                    }
                }
                else if (hdr.ipv6.isValid()) {
                    data_inspect_packet_ipv6();
                    if (hdr.udp.isValid()) {
                        insert_udp_int_for_udp();
                    } else if (hdr.tcp.isValid()) {
                        insert_udp_int_for_tcp_ipv6();
                    }
                }
            }
        }
        data_forward_t.apply();
    }
}

control TpsAggDeparser(packet_out packet,
                       inout headers hdr,
                       in metadata meta,
                       in ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md) {
    apply {

        /* For Standard and INT Packets */
        packet.emit(hdr.ethernet);
        packet.emit(hdr.arp);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.ipv6);
        packet.emit(hdr.udp);
        packet.emit(hdr.int_shim);
        packet.emit(hdr.int_header);
        packet.emit(hdr.int_meta_2);
        packet.emit(hdr.int_meta);
        packet.emit(hdr.udp_int);
        packet.emit(hdr.tcp);

    }
}

/*************************************************************************
****************  E G R E S S   P R O C E S S I N G   ********************
*************************************************************************/

control TpsAggEgress(inout headers hdr,
                     inout metadata meta,
                     in egress_intrinsic_metadata_t eg_intr_md,
                     in egress_intrinsic_metadata_from_parser_t eg_intr_md_from_prsr,
                     inout egress_intrinsic_metadata_for_deparser_t eg_intr_md_for_dprs,
                     inout egress_intrinsic_metadata_for_output_port_t eg_intr_md_for_oport) {

    apply {
    }
}

// Empty egress parser/control blocks
parser EmptyEgressParser(packet_in packet,
                         out headers hdr,
                         out metadata meta,
                         out egress_intrinsic_metadata_t eg_intr_md) {
    state start {
        transition accept;
    }
}

control EmptyEgressDeparser(packet_out packet,
                            inout headers hdr,
                            in metadata meta,
                            in egress_intrinsic_metadata_for_deparser_t eg_intr_dprsr_md) {
    apply {}
}

control EmptyEgress(inout headers hdr,
                    inout metadata meta,
                    in egress_intrinsic_metadata_t eg_intr_md,
                    in egress_intrinsic_metadata_from_parser_t eg_intr_md_from_prsr,
                    inout egress_intrinsic_metadata_for_deparser_t eg_intr_md_for_dprs,
                    inout egress_intrinsic_metadata_for_output_port_t eg_intr_md_for_oport) {
    apply {}
}

/*************************************************************************
***********************  S W I T C H  ************************************
*************************************************************************/

Pipeline(
    TpsAggParser(),
    TpsAggIngress(),
    TpsAggDeparser(),
    EmptyEgressParser(),
    TpsAggEgress(),
    EmptyEgressDeparser()
) pipe;
Switch(pipe) main;