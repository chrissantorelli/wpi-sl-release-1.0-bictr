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
 *
 * Supports two modes:
 *   1. Flat terrain (original stub) — when no DEM file is provided
 *   2. DEM terrain — loads a binary elevation grid, samples heights,
 *      performs LOS checks against terrain, and places reflectors on
 *      the actual surface
 */

#ifndef __BICTR_CHANNEL_H__
#define __BICTR_CHANNEL_H__

#include "sim.h"

typedef struct {
  float  *data;       /* row-major elevation grid (meters), south-to-north */
  double  min_lon, max_lon;
  double  min_lat, max_lat;
  int     n_lon, n_lat;
  double  pixel_size_lon; /* degrees per pixel in longitude */
  double  pixel_size_lat; /* degrees per pixel in latitude  */
} bictr_dem_t;

typedef struct {
  /* flat-terrain parameters (kept for backward compatibility) */
  double tx_rx_dist;
  double tx_height;
  double rx_height;

  /* reflector search */
  int    ref_count;
  double ring_radius_min;
  double ring_radius_max;
  double ring_radius_uncert;
  int    ring_count;
  int    ref_attempt_per_ring;

  /* ground reflection (regolith permittivity) */
  double permit_real;
  double permit_real_std;
  double permit_imag;
  double permit_imag_std;
  int    horiz_pol;

  /* Rayleigh fading */
  int    fading_paths;
  double doppler_spread;

  /* DEM terrain mode (empty dem_file => flat terrain fallback) */
  char   dem_file[512];
  double tx_lon, tx_lat;
  double rx_lon, rx_lat;
  double body_radius;     /* meters; default 1 737 400 for the Moon */
} bictr_config_t;

/* Load a BDEM binary file.  Returns 0 on success, -1 on failure. */
int bictr_dem_load(bictr_dem_t *dem, const char *filename);

/* Free a loaded DEM grid */
void bictr_dem_free(bictr_dem_t *dem);

/* Sample elevation at an arbitrary geographic point (bilinear interpolation).
 * Returns 0.0 if the point is outside the grid. */
double bictr_dem_get_height(const bictr_dem_t *dem, double lon, double lat);

/* Initialize the BICTR channel model.  If cfg->dem_file is non-empty the
 * terrain-aware path is used; otherwise the flat-terrain stub runs. */
void bictr_init_channel(channel_desc_t *chan_desc, const bictr_config_t *cfg);

#endif /* __BICTR_CHANNEL_H__ */
