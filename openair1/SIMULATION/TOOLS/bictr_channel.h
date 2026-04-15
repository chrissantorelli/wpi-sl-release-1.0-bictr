/*
 * Licensed to the OpenAirInterface (OAI) Software Alliance under one or more
 * contributor license agreements.  See the NOTICE file distributed with
 * this work for additional information regarding copyright ownership.
 * The OpenAirInterface Software Alliance licenses this file to You under
 * the OAI Public License, Version 1.1  (the "License"); you may not use this file
 * except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.openairinterface.org/?page_id=698
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *-------------------------------------------------------------------------------
 * BICTR (Barren Irregular Chaotic Terrain Ring) lunar channel model
 * Ported from Hao Wang's Python implementation (WPI MS Thesis, April 2025)
 * For integration into OAI RFsimulator
 */

#ifndef __BICTR_CHANNEL_H__
#define __BICTR_CHANNEL_H__

#include "sim.h"

typedef struct {
  double tx_rx_dist;
  double tx_height;
  double rx_height;
  int    ref_count;
  double ring_radius_min;
  double ring_radius_max;
  double ring_radius_uncert;
  int    ring_count;
  int    ref_attempt_per_ring;
  double permit_real;
  double permit_real_std;
  double permit_imag;
  double permit_imag_std;
  int    horiz_pol;
  int    fading_paths;
  double doppler_spread;
} bictr_config_t;

void bictr_init_channel(channel_desc_t *chan_desc, const bictr_config_t *cfg);

#endif /* __BICTR_CHANNEL_H__ */
