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
parser TpsAggParser(
    packet_in packet,
    out headers hdr,
    out metadata meta,
    out ingress_intrinsic_metadata_t ig_intr_md) {

    TofinoIngressParser() tofino_parser;

    state start {
        tofino_parser.apply(packet, ig_intr_md);
        meta.ingress_port = ig_intr_md.ingress_port;
        transition parse_ethernet;
    }

    state parse_ethernet {
        packet.extract(hdr.ethernet);
        meta.src_mac = hdr.ethernet.src_mac;

        transition select(hdr.ethernet.etherType) {
            TYPE_ARP: parse_arp;
            TYPE_IPV4: parse_ipv4;
            TYPE_IPV6: parse_ipv6;
            default: accept;
        }
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        meta.ipv6_addr = 0;
        meta.ipv4_addr = hdr.ipv4.dstAddr;
        transition select(hdr.ipv4.protocol) {
            TYPE_UDP: parse_udp_int;
            TYPE_TCP: parse_tcp;
            default: accept;
        }
    }

    state parse_ipv6 {
        packet.extract(hdr.ipv6);
        meta.ipv4_addr = 0;
        meta.ipv6_addr = hdr.ipv6.dstAddr;
        transition select(hdr.ipv6.next_hdr_proto) {
            TYPE_UDP: parse_udp_int;
            TYPE_TCP: parse_tcp;
            default: accept;
        }
    }

    state parse_udp_int {
        packet.extract(hdr.udp_int);
        meta.dst_port = hdr.udp_int.dst_port;
        transition select(hdr.udp_int.dst_port) {
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
        transition select(hdr.int_shim.next_proto){
            TYPE_UDP: parse_udp;
            TYPE_TCP: parse_tcp;
            default: accept;
        }
    }

    state parse_tcp {
        packet.extract(hdr.tcp);
        transition accept;
    }

    state parse_udp {
        packet.extract(hdr.udp);
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

control TpsAggIngress(
    inout headers hdr,
    inout metadata meta,
    in ingress_intrinsic_metadata_t ig_intr_md,
    in ingress_intrinsic_metadata_from_parser_t ig_prsr_md,
    inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
    inout ingress_intrinsic_metadata_for_tm_t ig_tm_md) {


    DirectCounter<bit<32>>(CounterType_t.PACKETS) droppedPackets;

    bool src_miss;
    PortId_t src_move;

    action smac_hit(PortId_t port) {
        src_move = port ^ ig_intr_md.ingress_port;
    }

    action smac_miss() {
        src_miss = true;
    }

    table smac {
        key = { hdr.ethernet.src_mac : exact; }
        actions = {
            smac_hit;
            smac_miss;
        }

        const default_action = smac_miss;
        size = 1024;
    }

    action data_forward(PortId_t port) {
        ig_tm_md.ucast_egress_port = port;
    }

    table data_forward_t {
        key = {
            hdr.ethernet.dst_mac: exact;
        }
        actions = {
            data_forward;
        }
        size = TABLE_SIZE;
    }

    action data_drop() {
        ig_dprsr_md.drop_ctl = 0x1;
        droppedPackets.count();
    }

    table data_drop_t {
        key = {
            hdr.ethernet.src_mac: exact;
            meta.ipv4_addr: exact;
            meta.ipv6_addr: exact;
            meta.dst_port: exact;
        }
        actions = {
            data_drop;
        }
        counters = droppedPackets;
        size = TABLE_SIZE;
    }

    action add_switch_id(bit<32> switch_id) {
        hdr.int_meta_2.setValid();
        // TODO/FIXME - doesn't look like we can set this value 2x but not having this will only break with the gateway scenario which is not required for the lab trial
        //hdr.ipv4.totalLen = hdr.ipv4.totalLen + BYTES_PER_SHIM;

        hdr.udp_int.len = hdr.udp.len + BYTES_PER_SHIM;
        hdr.ipv6.payload_len = hdr.ipv6.payload_len + BYTES_PER_SHIM;
        hdr.int_shim.length = hdr.int_shim.length + INT_SHIM_HOP_SIZE;
        hdr.int_header.remaining_hop_cnt = hdr.int_header.remaining_hop_cnt - 1;
        hdr.int_meta_2.switch_id = switch_id;
    }

    table add_switch_id_t {
        key = {
            hdr.udp_int.dst_port: exact;
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
    }

    action data_inspect_packet_ipv4() {
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
        hdr.int_shim.next_proto = hdr.ipv4.protocol;
        hdr.ipv4.protocol = TYPE_UDP;
        // TODO/FIXME - This value will be incorrect once the gateway with INT has been added into the mix
        hdr.ipv4.totalLen = hdr.ipv4.totalLen + (
            (INT_SHIM_BASE_SIZE * BYTES_PER_SHIM) + UDP_HDR_BYTES);
    }

    action data_inspect_packet_ipv6() {
        hdr.int_shim.next_proto = hdr.ipv6.next_hdr_proto;
        hdr.ipv6.next_hdr_proto = TYPE_UDP;
        // TODO/FIXME - This value will be incorrect once the gateway with INT has been added into the mix
        hdr.ipv6.payload_len = hdr.ipv6.payload_len + (
            (INT_SHIM_BASE_SIZE * BYTES_PER_SHIM) + UDP_HDR_BYTES);
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
        hdr.udp.setValid();
        hdr.udp.src_port = hdr.udp_int.src_port;
        hdr.udp.dst_port = hdr.udp_int.dst_port;
        hdr.udp.len = hdr.udp_int.len;
        hdr.udp_int.src_port = UDP_INT_SRC_PORT;
        hdr.udp_int.dst_port = UDP_INT_DST_PORT;

        // TODO/FIXME - This value will be incorrect once the gateway with INT has been added into the mix
        hdr.udp_int.len = hdr.udp.len + (
            (INT_SHIM_BASE_SIZE * BYTES_PER_SHIM) + UDP_HDR_BYTES);
    }

    action insert_udp_int_for_tcp_ipv4() {
        hdr.udp_int.setValid();
        hdr.udp_int.src_port = UDP_INT_SRC_PORT;
        hdr.udp_int.dst_port = UDP_INT_DST_PORT;
        hdr.udp_int.len = hdr.ipv4.totalLen - IPV4_HDR_BYTES;
    }

    action insert_udp_int_for_tcp_ipv6() {
        hdr.udp_int.setValid();
        hdr.udp_int.src_port = UDP_INT_SRC_PORT;
        hdr.udp_int.dst_port = UDP_INT_DST_PORT;
        hdr.udp_int.len = hdr.ipv6.payload_len;
    }

     apply {
        /* Value will be set with the udp_int.dst_port in the parser
           which would be incorrect in this case */
        if (hdr.tcp.isValid()) {
            meta.dst_port = hdr.tcp.dst_port;
        }

        if (hdr.int_shim.isValid()) {
            // Add switch ID into existing INT data
            add_switch_id_t.apply();
        } else {
            // Add IP & Protocol specific data to new INT data
            if (data_inspection_t.apply().hit) {
                if (hdr.udp_int.isValid()) {
                    insert_udp_int_for_udp();
                }
                if (hdr.ipv4.isValid()) {
                    data_inspect_packet_ipv4();
                    if (hdr.tcp.isValid()) {
                        insert_udp_int_for_tcp_ipv4();
                    }
                }
                else if (hdr.ipv6.isValid()) {
                    data_inspect_packet_ipv6();
                    if (hdr.tcp.isValid()) {
                        insert_udp_int_for_tcp_ipv6();
                    }
                }
            }
        }

        // Basic forwarding and drop logic
        if (data_drop_t.apply().miss) {
            if (hdr.arp.isValid() && hdr.arp.opcode == (bit<16>)0x1) {
                ig_dprsr_md.digest_type = DIGEST_TYPE_ARP;
                if (ig_intr_md.ingress_port != 0x1) {
                    data_forward(1);
                }
            } else {
                if (data_forward_t.apply().miss) {
                /*
                 * Send a digest if MAC address is unknown or if it is known
                 * but attached to a different port as long as it does not come
                 * in port 1, which should only be a switch. Nodes should be
                 * plugged into the others.
                 */
                    if (ig_intr_md.ingress_port > 1) {
                        // Send to NB switch at port 1
                        smac.apply();
                        if (src_miss == true || src_move != 0) {
                            ig_dprsr_md.digest_type = DIGEST_TYPE_FWD;
                        }
                        if (ig_intr_md.ingress_port != 0x1) {
                            data_forward(1);
                        }
                    }
                }
            }

            /*
             * Ensure packet gets dropped if we are trying to egress to the
             * ingress port
             */
            if (ig_intr_md.ingress_port == ig_tm_md.ucast_egress_port) {
                ig_dprsr_md.drop_ctl = 0x1;
            }
        }
    }
}

/*************************************************************************
***********************  D E P A R S E R  ********************************
*************************************************************************/

control TpsAggDeparser(
    packet_out packet,
    inout headers hdr,
    in metadata meta,
    in ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md) {

    Digest<digest_t>() smac_digest;
    Digest<digest_t>() arp_digest;

    apply {
        // Generate a digest, if digest_type is set in MAU.
        if (ig_dprsr_md.digest_type == DIGEST_TYPE_FWD) {
            smac_digest.pack({
                hdr.ethernet.src_mac,
                (bit<16>)meta.ingress_port
            });
        } else if (ig_dprsr_md.digest_type == DIGEST_TYPE_ARP) {
            arp_digest.pack({
                hdr.arp.src_mac,
                (bit<16>)meta.ingress_port
            });
        }

        /* For Standard and INT Packets */
        packet.emit(hdr.ethernet);
        packet.emit(hdr.arp);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.ipv6);
        packet.emit(hdr.udp_int);
        packet.emit(hdr.int_shim);
        packet.emit(hdr.int_header);
        packet.emit(hdr.int_meta_2);
        packet.emit(hdr.int_meta);
        packet.emit(hdr.udp);
        packet.emit(hdr.tcp);
    }
}

/*************************************************************************
****************  E G R E S S   P R O C E S S I N G   ********************
*************************************************************************/

parser TpsAggEgressParser(
    packet_in packet,
    out headers hdr,
    out metadata meta,
    out egress_intrinsic_metadata_t eg_intr_md) {

    TofinoEgressParser() tofino_parser;

    state start {
        tofino_parser.apply(packet, eg_intr_md);
        transition parse_ethernet;
    }
    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition accept;
    }

}

control TpsAggEgress(
    inout headers hdr,
    inout metadata meta,
    in egress_intrinsic_metadata_t eg_intr_md,
    in egress_intrinsic_metadata_from_parser_t eg_intr_md_from_prsr,
    inout egress_intrinsic_metadata_for_deparser_t eg_intr_md_for_dprs,
    inout egress_intrinsic_metadata_for_output_port_t eg_intr_md_for_oport) {

    apply {
    }
}

control TpsAggEgressDeparser(
    packet_out packet,
    inout headers hdr,
    in metadata meta,
    in egress_intrinsic_metadata_for_deparser_t eg_intr_dprsr_md) {

    apply {
        packet.emit(hdr);
    }
}

/*************************************************************************
***********************  S W I T C H  ************************************
*************************************************************************/

Pipeline(
    TpsAggParser(),
    TpsAggIngress(),
    TpsAggDeparser(),
    TpsAggEgressParser(),
    TpsAggEgress(),
    TpsAggEgressDeparser()
) pipe;
Switch(pipe) main;
