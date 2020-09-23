# Copyright (c) 2020 Cable Television Laboratories, Inc.
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
#
# Originally copied from:
#
# Copyright 2017-present Open Networking Foundation
#
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
#
import ipaddress
import logging

from bfrt_grpc.client import KeyTuple, DataTuple

from trans_sec.bfruntime_lib.bfrt_switch import BFRuntimeSwitch
from trans_sec.consts import UDP_INT_DST_PORT

logger = logging.getLogger('core_switch')

data_fwd_tbl = 'TpsCoreIngress.data_forward_t'
data_fwd_tbl_key = 'hdr.ethernet.dst_mac'
data_fwd_action = 'TpsCoreIngress.data_forward'
data_fwd_action_val = 'port'


class CoreSwitch(BFRuntimeSwitch):
    def __init__(self, sw_info, client_id=0, is_master=True):
        """
        Construct Switch class to control BMV2 switches running gateway.p4
        """
        logger.info('Instantiating BFRT CoreSwitch')
        super(self.__class__, self).__init__(sw_info, client_id, is_master)
        self.__set_table_field_annotations()

    def __set_table_field_annotations(self):
        table = self.get_table(data_fwd_tbl)
        table.info.key_field_annotation_add(data_fwd_tbl_key, "mac")

    def add_data_inspection(self, dev_id, dev_mac):
        logger.info('Adding data inspection to switch ID [%s] and MAC [%s]',
                    dev_id, dev_mac)
        raise NotImplementedError

    def add_data_forward(self, dst_mac, ingress_port):
        logger.info(
            'Inserting port - [%s] with key - [%s] into '
            'TpsCoreIngress.data_forward_t', ingress_port, dst_mac)
        self.insert_table_entry(data_fwd_tbl,
                                data_fwd_action,
                                [KeyTuple(data_fwd_tbl_key,
                                          value=dst_mac)],
                                [DataTuple(data_fwd_action_val,
                                           val=int(ingress_port))])

    def del_data_forward(self, dst_mac):
        logger.info(
            'Deleting table entry with key - [%s] from %s',
            dst_mac, data_fwd_tbl)
        self.delete_table_entry(data_fwd_tbl,
                                [KeyTuple(data_fwd_tbl_key, value=dst_mac)])

    def add_switch_id(self, dev_id):
        pass

    def setup_telemetry_rpt(self, ae_ip):
        logger.info(
            'Setting up telemetry report on core device [%s] with '
            'AE IP - [%s]', self.device_id, ae_ip)

        ip_addr = ipaddress.ip_address(ae_ip)
        action_name = 'TpsCoreEgress.setup_telem_rpt_ipv{}'.format(
            ip_addr.version)
        self.insert_table_entry('TpsCoreEgress.setup_telemetry_rpt_t',
                                action_name,
                                [KeyTuple('hdr.udp_int.dst_port',
                                          value=UDP_INT_DST_PORT)],
                                [DataTuple('ae_ip',
                                           val=bytearray(ip_addr.packed))])
