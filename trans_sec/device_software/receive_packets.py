#!/usr/bin/env python

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
import argparse
import logging
import sys

from scapy.all import bind_layers, sniff
from scapy.layers.inet import IP, UDP
from scapy.layers.l2 import Ether

from trans_sec.packet.inspect_layer import IntShim, IntHeader, IntMeta1, \
    IntMeta2, SourceIntMeta

logger = logging.getLogger('receive_packets')
FORMAT = '%(levelname)s %(asctime)-15s %(filename)s %(message)s'


def get_args():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        '-i', '--iface', help='The network interface on which to sniff',
        required=True, dest='iface')
    parser.add_argument(
        '-f', '--logfile', help='File to log to defaults to console',
        required=False, dest='log_file')
    parser.add_argument(
        '-ih', '--int-hops', help='Number of expected INT hops, no INT when 0',
        required=False, default=0, dest='int_hops', type=int)
    parser.add_argument(
        '-d', '--duration', default=0, dest='duration', type=int,
        help='Number of seconds to sniff - 0 is indefinite')
    parser.add_argument(
        '-l', '--loglevel',
        help='Log Level <DEBUG|INFO|WARNING|ERROR> defaults to INFO',
        required=False, default='INFO', dest='log_level')
    return parser.parse_args()


def __log_packet(packet, int_hops):
    try:
        ip_proto = packet[IP].proto
    except Exception:
        logger.warn('Unable to process packet - [%s]', packet.summary())
        return

    if int_hops > 0 and ip_proto == 0xfd:
        logger.debug('INT Packet received')

        mac1 = None
        switch_id_1 = None
        switch_id_2 = None
        switch_id_3 = None
        if int_hops == 1:
            mac1 = packet[SourceIntMeta].orig_mac
            switch_id_1 = packet[SourceIntMeta].switch_id
        if int_hops == 2:
            mac1 = packet[SourceIntMeta].orig_mac
            switch_id_1 = packet[SourceIntMeta].switch_id
            switch_id_2 = packet[IntMeta2].switch_id
        if int_hops == 3:
            mac1 = packet[SourceIntMeta].orig_mac
            switch_id_1 = packet[SourceIntMeta].switch_id
            switch_id_2 = packet[IntMeta2].switch_id
            switch_id_3 = packet[IntMeta1].switch_id

        int_data = dict(
            eth_src_mac=packet[Ether].src,
            eth_dst_mac=packet[Ether].dst,
            src_ip=packet[IP].src,
            dst_ip=packet[IP].dst,
            mac1=mac1,
            switch_id_1=switch_id_1,
            switch_id_2=switch_id_2,
            switch_id_3=switch_id_3,
            src_port=packet[UDP].sport,
            dst_port=packet[UDP].dport,
            packetLen=len(packet),
        )
        logger.warn('INT Packet data - [%s]', int_data)
    elif int_hops < 1 and ip_proto != 0xfd:
        logger.debug('Non INT Packet received')
        logger.warn('Packet data - [%s]', packet.summary())
    else:
        logger.debug('Nothing to log here')


def device_sniff(iface, duration, int_hops):
    if int_hops > 0:
        logger.info('Binding layers for INT with hops - [%s]', int_hops)

        bind_layers(Ether, IP)
        bind_layers(IP, IntShim)
        bind_layers(IntShim, IntHeader)
        if int_hops == 1:
            bind_layers(IntHeader, SourceIntMeta)
            bind_layers(SourceIntMeta, UDP)
        if int_hops == 2:
            bind_layers(IntHeader, IntMeta2)
            bind_layers(IntMeta2, SourceIntMeta)
            bind_layers(SourceIntMeta, UDP)
        if int_hops == 3:
            bind_layers(IntHeader, IntMeta1)
            bind_layers(IntMeta1, IntMeta2)
            bind_layers(IntMeta2, SourceIntMeta)
            bind_layers(SourceIntMeta, UDP)
        if int_hops > 3:
            raise Exception('Cannot currently support more than 3 hops')
    else:
        logger.info('Binding layers for UDP')
        bind_layers(Ether, IP)
        bind_layers(IP, UDP)

    logger.info("Sniffing for packets on iface - [%s]", iface)
    sys.stdout.flush()

    if duration > 0:
        logger.info('Running sniffer for [%s] seconds', duration)
        sniff(iface=iface, prn=lambda packet: __log_packet(packet, int_hops),
              timeout=duration)
    else:
        logger.info('Running sniffer indefinitely')
        sniff(iface=iface, prn=lambda packet: __log_packet(packet, int_hops))


if __name__ == '__main__':
    cmd_args = get_args()

    numeric_level = getattr(logging, cmd_args.log_level, None)
    if cmd_args.log_file:
        logging.basicConfig(format=FORMAT, level=numeric_level,
                            filename=cmd_args.log_file)
    else:
        logging.basicConfig(format=FORMAT, level=numeric_level)

    logger.info('Logger initialized')

    device_sniff(cmd_args.iface, cmd_args.duration, cmd_args.int_hops)
