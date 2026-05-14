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
 *
 * Two modes:
 *   - Flat terrain  (original stub)  — when dem_file is empty
 *   - DEM terrain   (full model)     — loads binary elevation grid, samples
 *     chaotic south-pole heights, and gates reflectors on terrain LOS
 */

#include <math.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdbool.h>
#include <complex.h>

#include "bictr_channel.h"
#include "sim.h"
#include "common/utils/LOG/log.h"
#include "assertions.h"

#define SPEED_OF_LIGHT 299792458.0
#define DEG2RAD(d)     ((d) * M_PI / 180.0)
#define RAD2DEG(r)     ((r) * 180.0 / M_PI)

/* rfsimulator rxAddInput() convolves at raw sample rate with no OFDM symbol / CP
 * boundary handling. Multipath tails inject inter-symbol energy that NR decoders
 * cannot treat like a proper TDL under CP — same geometry works for AWGN (L=1).
 * Folding the discrete CIR onto one tap keeps BICTR path gain/link stats while
 * restoring a frequency-flat channel in this interface. Set to 0 to experiment
 * with full multipath (expect high BLER until a CP-aware FD path exists). */
#ifndef BICTR_RFSIM_FOLD_MULTIPATH
#define BICTR_RFSIM_FOLD_MULTIPATH 1
#endif

/* ------------------------------------------------------------------ */
/*  DEM I/O                                                           */
/* ------------------------------------------------------------------ */

int bictr_dem_load(bictr_dem_t *dem, const char *filename)
{
  FILE *f = fopen(filename, "rb");
  if (!f) {
    LOG_E(OCM, "[BICTR] Cannot open DEM file: %s\n", filename);
    return -1;
  }

  char magic[4];
  if (fread(magic, 1, 4, f) != 4 || memcmp(magic, "BDEM", 4) != 0) {
    LOG_E(OCM, "[BICTR] Bad magic in DEM file: %s\n", filename);
    fclose(f);
    return -1;
  }

  int32_t n_lon, n_lat;
  if (fread(&n_lon, 4, 1, f) != 1 || fread(&n_lat, 4, 1, f) != 1) {
    LOG_E(OCM, "[BICTR] Failed to read DEM dimensions: %s\n", filename);
    fclose(f);
    return -1;
  }

  double bounds[4];
  if (fread(bounds, 8, 4, f) != 4) {
    LOG_E(OCM, "[BICTR] Failed to read DEM bounds: %s\n", filename);
    fclose(f);
    return -1;
  }

  dem->n_lon   = n_lon;
  dem->n_lat   = n_lat;
  dem->min_lon = bounds[0];
  dem->max_lon = bounds[1];
  dem->min_lat = bounds[2];
  dem->max_lat = bounds[3];
  dem->pixel_size_lon = (dem->max_lon - dem->min_lon) / (n_lon > 1 ? n_lon - 1 : 1);
  dem->pixel_size_lat = (dem->max_lat - dem->min_lat) / (n_lat > 1 ? n_lat - 1 : 1);

  size_t total = (size_t)n_lon * n_lat;
  dem->data = (float *)malloc(total * sizeof(float));
  AssertFatal(dem->data != NULL, "[BICTR] DEM allocation failed (%zu floats)\n", total);

  size_t nread = fread(dem->data, sizeof(float), total, f);
  fclose(f);

  if (nread != total) {
    LOG_E(OCM, "[BICTR] DEM read short: got %zu, expected %zu\n", nread, total);
    free(dem->data);
    dem->data = NULL;
    return -1;
  }

  LOG_I(OCM, "[BICTR] DEM loaded: %s (%dx%d, lon [%.2f,%.2f] lat [%.2f,%.2f])\n",
        filename, n_lon, n_lat, dem->min_lon, dem->max_lon, dem->min_lat, dem->max_lat);
  return 0;
}

void bictr_dem_free(bictr_dem_t *dem)
{
  if (dem->data) { free(dem->data); dem->data = NULL; }
}

double bictr_dem_get_height(const bictr_dem_t *dem, double lon, double lat)
{
  if (!dem->data)
    return 0.0;

  double fx = (lon - dem->min_lon) / dem->pixel_size_lon;
  double fy = (lat - dem->min_lat) / dem->pixel_size_lat;

  int ix = (int)floor(fx);
  int iy = (int)floor(fy);

  if (ix < 0 || iy < 0 || ix >= dem->n_lon - 1 || iy >= dem->n_lat - 1)
    return 0.0;

  double dx = fx - ix;
  double dy = fy - iy;

  float z00 = dem->data[iy       * dem->n_lon + ix    ];
  float z10 = dem->data[iy       * dem->n_lon + ix + 1];
  float z01 = dem->data[(iy + 1) * dem->n_lon + ix    ];
  float z11 = dem->data[(iy + 1) * dem->n_lon + ix + 1];

  return z00 * (1 - dx) * (1 - dy)
       + z10 * dx       * (1 - dy)
       + z01 * (1 - dx) * dy
       + z11 * dx       * dy;
}

/* ------------------------------------------------------------------ */
/*  Spherical geometry helpers  (ported from spatial.py)               */
/* ------------------------------------------------------------------ */

static void geo_to_3d(double body_radius, double lon_deg, double lat_deg,
                       double height_bias, double *ox, double *oy, double *oz)
{
  double inc = DEG2RAD(90.0 - lat_deg);
  double azi = DEG2RAD(lon_deg);
  double r   = body_radius + height_bias;
  *ox = r * sin(inc) * cos(azi);
  *oy = r * sin(inc) * sin(azi);
  *oz = r * cos(inc);
}

static double dist3d(double ax, double ay, double az,
                     double bx, double by, double bz)
{
  double dx = ax - bx, dy = ay - by, dz = az - bz;
  return sqrt(dx*dx + dy*dy + dz*dz);
}

/* Forward geodesic: given a starting point, bearing (radians CW from north),
 * and surface distance (m), return destination (lon, lat) in degrees.
 * Matches spatial.py Body.destination(). */
static void geo_destination(double body_radius,
                            double lon_deg, double lat_deg,
                            double bearing, double distance,
                            double *out_lon, double *out_lat)
{
  double dist = distance / body_radius;
  double lon1 = DEG2RAD(lon_deg);
  double lat1 = DEG2RAD(lat_deg);
  double lat2, lon2;

  if (lat_deg == 90.0 || lat_deg == -90.0) {
    lon2 = bearing - M_PI;
    lat2 = (lat_deg == 90.0) ? (M_PI / 2.0 - dist) : (-M_PI / 2.0 + dist);
  } else {
    lat2 = asin(sin(lat1) * cos(dist) + cos(lat1) * sin(dist) * cos(bearing));
    lon2 = lon1 + atan2(sin(bearing) * sin(dist) * cos(lat1),
                        cos(dist) - sin(lat1) * sin(lat2));
  }
  *out_lon = RAD2DEG(lon2);
  *out_lat = RAD2DEG(lat2);
}

/* LOS terrain check: sample elevation along a great-circle track and verify
 * the straight-line signal clears the terrain at every sample.
 * Returns 1 if LOS exists, 0 if terrain obstructs.  Mirrors spatial.py checkLOS(). */
static int dem_check_los(const bictr_dem_t *dem, double body_radius,
                         double lon1, double lat1, double h1,
                         double lon2, double lat2, double h2)
{
  if (!dem->data)
    return 1; /* no DEM => assume LOS (flat terrain fallback) */

  /* Number of samples along the track — at least one per DEM pixel */
  double arc_dist;
  {
    double la1 = DEG2RAD(lat1), la2 = DEG2RAD(lat2);
    double dlon = DEG2RAD(lon2 - lon1);
    double a = sin((la2 - la1) / 2); a *= a;
    a += cos(la1) * cos(la2) * sin(dlon / 2) * sin(dlon / 2);
    arc_dist = 2.0 * asin(sqrt(a)); /* central angle in radians */
  }
  double surface_dist = arc_dist * body_radius;
  double pixel_m = DEG2RAD(dem->pixel_size_lat) * body_radius;
  int n_samples = (int)(surface_dist / pixel_m) + 2;
  if (n_samples < 3) n_samples = 3;
  if (n_samples > 500) n_samples = 500;

  /* Sample terrain heights and interpolate the LOS line */
  double ground_start = bictr_dem_get_height(dem, lon1, lat1);
  double ground_end   = bictr_dem_get_height(dem, lon2, lat2);
  double los_start    = ground_start + h1;
  double los_end      = ground_end   + h2;

  for (int k = 1; k < n_samples - 1; k++) {
    double t = (double)k / (n_samples - 1);
    /* Intermediate point via linear lat/lon interpolation (good for short arcs) */
    double lon_k = lon1 + t * (lon2 - lon1);
    double lat_k = lat1 + t * (lat2 - lat1);
    double terrain_h = bictr_dem_get_height(dem, lon_k, lat_k);
    double los_h     = los_start + t * (los_end - los_start);
    if (los_h < terrain_h)
      return 0;
  }
  return 1;
}

/* ------------------------------------------------------------------ */
/*  Common helpers                                                     */
/* ------------------------------------------------------------------ */

typedef struct {
  double delay_s;
  double complex phasor;
} bictr_path_t;

static int delay_to_samples(double fs_hz, double delay_s)
{
  return (int)round(delay_s * fs_hz);
}

static double free_space_pathloss_amplitude(double freq_hz, double dist_m)
{
  return SPEED_OF_LIGHT / (4.0 * M_PI * dist_m * freq_hz);
}

/* ------------------------------------------------------------------ */
/*  Reflector placement — FLAT terrain  (original stub)                */
/* ------------------------------------------------------------------ */

static void generate_reflectors_flat(const bictr_config_t *cfg,
                                     double fs_hz,
                                     double carrier_hz,
                                     double los_dist,
                                     double los_pl,
                                     bictr_path_t *paths,
                                     int *num_paths_out,
                                     int max_paths)
{
  const double tx_x = 0.0, tx_y = 0.0, tx_z = cfg->tx_height;
  const double rx_x = cfg->tx_rx_dist, rx_y = 0.0, rx_z = cfg->rx_height;

  int used_delay_samples[256];
  int n_used = 0;
  int los_delay_sample = delay_to_samples(fs_hz, los_dist / SPEED_OF_LIGHT);
  used_delay_samples[n_used++] = los_delay_sample;

  double curr_radius = cfg->ring_radius_min;
  double radius_step = (cfg->ring_radius_max - cfg->ring_radius_min) / cfg->ring_count;
  int found = 0;

  while (curr_radius <= cfg->ring_radius_max && found < cfg->ref_count && found < max_paths) {
    for (int attempt = 0; attempt < cfg->ref_attempt_per_ring && found < cfg->ref_count; attempt++) {
      double r = curr_radius + (2.0 * uniformrandom() - 1.0) * cfg->ring_radius_uncert;
      if (r < 0.1)
        r = 0.1;
      double theta = uniformrandom() * 2.0 * M_PI;

      double ref_x = rx_x + r * cos(theta);
      double ref_y = rx_y + r * sin(theta);
      double ref_z = 0.0;

      double dx_tr = ref_x - tx_x, dy_tr = ref_y - tx_y, dz_tr = ref_z - tx_z;
      double dist_tx_ref = sqrt(dx_tr * dx_tr + dy_tr * dy_tr + dz_tr * dz_tr);

      double dx_rr = ref_x - rx_x, dy_rr = ref_y - rx_y, dz_rr = ref_z - rx_z;
      double dist_ref_rx = sqrt(dx_rr * dx_rr + dy_rr * dy_rr + dz_rr * dz_rr);

      double total_dist = dist_tx_ref + dist_ref_rx;
      double delay_s = total_dist / SPEED_OF_LIGHT;
      int d_samp = delay_to_samples(fs_hz, delay_s);

      int duplicate = 0;
      for (int k = 0; k < n_used; k++) {
        if (used_delay_samples[k] == d_samp) {
          duplicate = 1;
          break;
        }
      }
      if (duplicate)
        continue;

      double cos_full = (dist_tx_ref * dist_tx_ref + dist_ref_rx * dist_ref_rx - los_dist * los_dist)
                        / (2.0 * dist_tx_ref * dist_ref_rx);
      if (cos_full > 1.0) cos_full = 1.0;
      if (cos_full < -1.0) cos_full = -1.0;
      double reflect_angle = (M_PI - acos(cos_full)) / 2.0;

      double eps_r = gaussZiggurat(cfg->permit_real, cfg->permit_real_std);
      double eps_i = gaussZiggurat(cfg->permit_imag, cfg->permit_imag_std);
      double complex eps_g = eps_r + I * eps_i;

      double cos2_theta = cos(reflect_angle) * cos(reflect_angle);
      double complex Z;
      if (cfg->horiz_pol) {
        Z = csqrt(eps_g - cos2_theta);
      } else {
        Z = csqrt(eps_g - cos2_theta) / eps_g;
      }
      double complex Gamma = (sin(reflect_angle) - Z) / (sin(reflect_angle) + Z);

      double ref_pl = free_space_pathloss_amplitude(carrier_hz, total_dist);
      double rand_phase = uniformrandom() * 2.0 * M_PI;
      double complex phasor = ref_pl * Gamma * cexp(I * rand_phase);

      paths[found].delay_s = delay_s;
      paths[found].phasor = phasor;
      found++;
      if (n_used < 256)
        used_delay_samples[n_used++] = d_samp;
    }
    curr_radius += radius_step;
  }
  *num_paths_out = found;
}

/* ------------------------------------------------------------------ */
/*  Reflector placement — DEM terrain  (full BICTR model)              */
/* ------------------------------------------------------------------ */

static void generate_reflectors_terrain(const bictr_config_t *cfg,
                                        const bictr_dem_t *dem,
                                        double fs_hz,
                                        double carrier_hz,
                                        double los_dist,
                                        double tx_3d[3], double rx_3d[3],
                                        bictr_path_t *paths,
                                        int *num_paths_out,
                                        int max_paths)
{
  int used_delay_samples[256];
  int n_used = 0;
  int los_delay_sample = delay_to_samples(fs_hz, los_dist / SPEED_OF_LIGHT);
  used_delay_samples[n_used++] = los_delay_sample;

  double curr_radius = cfg->ring_radius_min;
  double radius_step = (cfg->ring_radius_max - cfg->ring_radius_min) / cfg->ring_count;
  int found = 0;

  while (curr_radius <= cfg->ring_radius_max && found < cfg->ref_count && found < max_paths) {
    for (int attempt = 0; attempt < cfg->ref_attempt_per_ring && found < cfg->ref_count; attempt++) {
      double r = curr_radius + (2.0 * uniformrandom() - 1.0) * cfg->ring_radius_uncert;
      if (r < 0.1)
        r = 0.1;
      double theta = uniformrandom() * 2.0 * M_PI;

      /* Place reflector on ring around RX using spherical forward projection */
      double ref_lon, ref_lat;
      geo_destination(cfg->body_radius, cfg->rx_lon, cfg->rx_lat, theta, r,
                      &ref_lon, &ref_lat);

      /* Sample terrain height at reflector location (chaotic elevation) */
      double ref_ground_h = bictr_dem_get_height(dem, ref_lon, ref_lat);

      /* Convert reflector to 3D (sitting on the terrain surface) */
      double ref_3d[3];
      geo_to_3d(cfg->body_radius, ref_lon, ref_lat, ref_ground_h,
                &ref_3d[0], &ref_3d[1], &ref_3d[2]);

      double dist_tx_ref = dist3d(tx_3d[0], tx_3d[1], tx_3d[2],
                                  ref_3d[0], ref_3d[1], ref_3d[2]);
      double dist_ref_rx = dist3d(ref_3d[0], ref_3d[1], ref_3d[2],
                                  rx_3d[0], rx_3d[1], rx_3d[2]);
      double total_dist  = dist_tx_ref + dist_ref_rx;
      double delay_s     = total_dist / SPEED_OF_LIGHT;
      int d_samp = delay_to_samples(fs_hz, delay_s);

      /* Skip duplicate delay bins */
      int duplicate = 0;
      for (int k = 0; k < n_used; k++) {
        if (used_delay_samples[k] == d_samp) {
          duplicate = 1;
          break;
        }
      }
      if (duplicate)
        continue;

      /* LOS check: TX->reflector and reflector->RX must both clear terrain */
      if (!dem_check_los(dem, cfg->body_radius,
                         cfg->tx_lon, cfg->tx_lat, cfg->tx_height,
                         ref_lon, ref_lat, 0.0))
        continue;
      if (!dem_check_los(dem, cfg->body_radius,
                         ref_lon, ref_lat, 0.0,
                         cfg->rx_lon, cfg->rx_lat, cfg->rx_height))
        continue;

      /* Reflection angle via law of cosines (thesis Eq. 10) */
      double cos_full = (dist_tx_ref * dist_tx_ref + dist_ref_rx * dist_ref_rx
                         - los_dist * los_dist)
                        / (2.0 * dist_tx_ref * dist_ref_rx);
      if (cos_full > 1.0) cos_full = 1.0;
      if (cos_full < -1.0) cos_full = -1.0;
      double reflect_angle = (M_PI - acos(cos_full)) / 2.0;

      /* Complex relative permittivity (Eq. 9: ε' + jε'', matching Python) */
      double eps_r = gaussZiggurat(cfg->permit_real, cfg->permit_real_std);
      double eps_i = gaussZiggurat(cfg->permit_imag, cfg->permit_imag_std);
      double complex eps_g = eps_r + I * eps_i;

      /* Fresnel reflection coefficient (thesis Eqs. 8-9) */
      double cos2_theta = cos(reflect_angle) * cos(reflect_angle);
      double complex Z;
      if (cfg->horiz_pol) {
        Z = csqrt(eps_g - cos2_theta);
      } else {
        Z = csqrt(eps_g - cos2_theta) / eps_g;
      }
      double complex Gamma = (sin(reflect_angle) - Z) / (sin(reflect_angle) + Z);

      double ref_pl = free_space_pathloss_amplitude(carrier_hz, total_dist);
      double rand_phase = uniformrandom() * 2.0 * M_PI;
      double complex phasor = ref_pl * Gamma * cexp(I * rand_phase);

      paths[found].delay_s = delay_s;
      paths[found].phasor = phasor;
      found++;
      if (n_used < 256)
        used_delay_samples[n_used++] = d_samp;
    }
    curr_radius += radius_step;
  }
  *num_paths_out = found;
}

/* ------------------------------------------------------------------ */
/*  Rayleigh fading (Zheng-Xiao, unchanged)                            */
/* ------------------------------------------------------------------ */

static void generate_rayleigh_fading(int fading_paths, double doppler_spread,
                                     double carrier_hz, double fs_hz,
                                     int length, double complex *out)
{
  int M = fading_paths / 4;
  if (M < 1) M = 1;

  double wd = 2.0 * M_PI * doppler_spread * carrier_hz / SPEED_OF_LIGHT;
  double inv_fs = 1.0 / fs_hz;

  memset(out, 0, length * sizeof(double complex));

  for (int n = 1; n <= M; n++) {
    double theta_n = (2.0 * uniformrandom() - 1.0) * M_PI;
    double phi_n   = (2.0 * uniformrandom() - 1.0) * M_PI;
    double psi_n   = (2.0 * uniformrandom() - 1.0) * M_PI;
    double alpha_n = (2.0 * M_PI * n - M_PI + theta_n) / (4.0 * M);
    double wd_cos  = wd * cos(alpha_n);

    for (int t = 0; t < length; t++) {
      double time_s = t * inv_fs;
      double cosval = cos(wd_cos * time_s + phi_n);
      out[t] += cos(psi_n) * cosval;
    }
  }

  for (int n = 1; n <= M; n++) {
    double theta_n = (2.0 * uniformrandom() - 1.0) * M_PI;
    double phi_n   = (2.0 * uniformrandom() - 1.0) * M_PI;
    double psi_n   = (2.0 * uniformrandom() - 1.0) * M_PI;
    double alpha_n = (2.0 * M_PI * n - M_PI + theta_n) / (4.0 * M);
    double wd_cos  = wd * cos(alpha_n);

    for (int t = 0; t < length; t++) {
      double time_s = t * inv_fs;
      double cosval = cos(wd_cos * time_s + phi_n);
      out[t] += I * sin(psi_n) * cosval;
    }
  }

  double scale = 2.0 / sqrt((double)M);
  double sum_power = 0.0;
  for (int t = 0; t < length; t++) {
    out[t] *= scale;
    sum_power += creal(out[t]) * creal(out[t]) + cimag(out[t]) * cimag(out[t]);
  }
  double avg_power = sum_power / length;
  if (avg_power > 1e-30) {
    double norm = sqrt(1.0 / avg_power);
    for (int t = 0; t < length; t++)
      out[t] *= norm;
  }
}

/* ------------------------------------------------------------------ */
/*  channel_desc_t teardown helper                                     */
/* ------------------------------------------------------------------ */

static void bictr_free_placeholder(channel_desc_t *d)
{
  if (d->amps) { free(d->amps); d->amps = NULL; }
  if (d->delays) { free(d->delays); d->delays = NULL; }
  if (d->a) {
    for (int i = 0; i < d->nb_taps; i++)
      free(d->a[i]);
    free(d->a); d->a = NULL;
  }
  if (d->ch) {
    for (int i = 0; i < d->nb_tx * d->nb_rx; i++)
      free(d->ch[i]);
    free(d->ch); d->ch = NULL;
  }
  if (d->chF) {
    for (int i = 0; i < d->nb_tx * d->nb_rx; i++)
      free(d->chF[i]);
    free(d->chF); d->chF = NULL;
  }
  if (d->R_sqrt) {
    for (int i = 0; i < d->nb_taps; i++)
      free(d->R_sqrt[i]);
    free(d->R_sqrt); d->R_sqrt = NULL;
  }
  d->free_flags = 0;
}

/* ------------------------------------------------------------------ */
/*  FIR construction + channel_desc_t population  (shared by both      */
/*  flat and terrain paths)                                            */
/* ------------------------------------------------------------------ */

static void build_channel_fir(channel_desc_t *chan_desc,
                              const bictr_config_t *cfg,
                              double los_delay, double complex los_phasor,
                              bictr_path_t *ref_paths, int n_reflectors,
                              double fs_hz, double carrier_hz)
{
  const int nb_tx = chan_desc->nb_tx;
  const int nb_rx = chan_desc->nb_rx;
  int total_paths = 1 + n_reflectors;

  /* Collect delay samples relative to earliest path */
  int all_delay_samp[256];
  all_delay_samp[0] = delay_to_samples(fs_hz, los_delay);
  for (int i = 0; i < n_reflectors; i++)
    all_delay_samp[1 + i] = delay_to_samples(fs_hz, ref_paths[i].delay_s);

  int min_ds = all_delay_samp[0], max_ds = all_delay_samp[0];
  for (int i = 1; i < total_paths; i++) {
    if (all_delay_samp[i] < min_ds) min_ds = all_delay_samp[i];
    if (all_delay_samp[i] > max_ds) max_ds = all_delay_samp[i];
  }

  int fir_length = max_ds - min_ds + 1;
  if (fir_length < 1) fir_length = 1;
  if (fir_length > 255) {
    LOG_W(OCM, "[BICTR] FIR length %d exceeds uint8_t max, clamping to 255\n", fir_length);
    fir_length = 255;
  }

  double complex *fir = calloc(fir_length, sizeof(double complex));
  AssertFatal(fir != NULL, "[BICTR] Failed to allocate FIR array\n");

  bool *has_specular = calloc((size_t)fir_length, sizeof(bool));
  AssertFatal(has_specular != NULL, "[BICTR] Failed to allocate specular mask\n");

  int los_idx = all_delay_samp[0] - min_ds;
  if (los_idx >= 0 && los_idx < fir_length && cabs(los_phasor) > 1e-30) {
    fir[los_idx] += los_phasor;
    has_specular[los_idx] = true;
  }

  for (int i = 0; i < n_reflectors; i++) {
    int idx = all_delay_samp[1 + i] - min_ds;
    if (idx >= 0 && idx < fir_length) {
      fir[idx] += ref_paths[i].phasor;
      has_specular[idx] = true;
    }
  }

  double los_pl = cabs(los_phasor);
  /* Diffuse component: add only on specular delay bins (avoids a synthetic dense CIR). */
  if (cfg->fading_paths > 0 && fir_length > 0) {
    double complex *fading = calloc(fir_length, sizeof(double complex));
    AssertFatal(fading != NULL, "[BICTR] Failed to allocate fading array\n");

    generate_rayleigh_fading(cfg->fading_paths, cfg->doppler_spread,
                             carrier_hz, fs_hz, fir_length, fading);
    double fading_scale = los_pl / (double)fir_length;
    if (fading_scale < 1e-30 && n_reflectors > 0) {
      double peak = 0.0;
      for (int t = 0; t < fir_length; t++) {
        double a = cabs(fir[t]);
        if (a > peak) peak = a;
      }
      fading_scale = peak / (double)fir_length;
    }
    for (int t = 0; t < fir_length; t++) {
      if (!has_specular[t]) continue;
      fir[t] += fading[t] * fading_scale;
    }
    free(fading);
    LOG_I(OCM, "[BICTR] Rayleigh fading (sparse taps): paths=%d scale=%.6e\n",
          cfg->fading_paths, fading_scale);
  }

  /* Thesis Eq. 6: scale combined LOS + reflector sum */
  double norm_factor = 1.0 / (cfg->ref_count + 1);
  for (int t = 0; t < fir_length; t++)
    fir[t] *= norm_factor;

  /* Distanceless FIR: strip LOS FSPL amplitude (rfsimulator uses ploss_dB if needed). */
  if (los_pl > 1e-30) {
    double scale = 1.0 / los_pl;
    for (int t = 0; t < fir_length; t++)
      fir[t] *= scale;
  }

  /* Undo Eq. 6 combiner attenuation so nominal tap gain matches AWGN identity (~1)
   * for the same noise_power_dB in apply_channelmod.c (UL/DL common calibration). */
  {
    double oai_gain = (double)(cfg->ref_count + 1);
    for (int t = 0; t < fir_length; t++)
      fir[t] *= oai_gain;
  }

  free(has_specular);

  /* Bound peak of |y[n]| = |Σ h[l] x[n-l]| ≤ (Σ|h[l]|) max|x| for rfsimulator int16 I/Q.
   * L2-only norm allows Σ|h| ≈ √L (e.g. ~6.8 for L≈46) → clipping vs AWGN (Σ|h|=1). */
  {
    double l1 = 0.0;
    for (int t = 0; t < fir_length; t++)
      l1 += cabs(fir[t]);
    if (l1 > 1e-30) {
      for (int t = 0; t < fir_length; t++)
        fir[t] /= l1;
    }
    LOG_I(OCM, "[BICTR] FIR L1-normalized (Σ|h_k|=1), fir_length=%d (rfsim int16-safe)\n",
          fir_length);
  }

  int rfsim_folded = 0;
#if BICTR_RFSIM_FOLD_MULTIPATH
  if (fir_length > 1) {
    int len_in = fir_length;
    double complex fold = 0.0;
    for (int t = 0; t < fir_length; t++)
      fold += fir[t];
    double complex *fir1 = realloc(fir, sizeof(double complex));
    AssertFatal(fir1 != NULL, "[BICTR] realloc for rfsim CIR fold failed\n");
    fir = fir1;
    fir[0] = fold;
    fir_length = 1;
    rfsim_folded = 1;
    LOG_W(OCM, "[BICTR] RFSIM: folded %d-tap CIR to 1 tap (OFDM/CP not modeled in rxAddInput)\n",
          len_in);
  }
#endif

  /* AWGN uses a single unity-magnitude tap; same noise_power_dB then assumes |h|=1 on signal.
   * After L1 + fold, |sum h_k| can be < 1 (phasor cancellation). Normalize phase-preserving. */
  if (fir_length == 1) {
    double a = cabs(fir[0]);
    if (a > 1e-30)
      fir[0] /= a;
    LOG_I(OCM, "[BICTR] Effective SISO tap scaled to |h|=1 (AWGN-comparable signal power)\n");
  }

  double total_energy = 0.0;
  for (int t = 0; t < fir_length; t++)
    total_energy += creal(fir[t]) * creal(fir[t]) + cimag(fir[t]) * cimag(fir[t]);
  double energy_dB = 10.0 * log10(total_energy > 1e-30 ? total_energy : 1e-30);
  LOG_I(OCM, "[BICTR] FIR ready: total_energy=%.6f (%.2f dB) fir_length=%d "
             "eq6_div=%d fading=%d (OAI nominal gain)\n",
        total_energy, energy_dB, fir_length,
        cfg->ref_count + 1, cfg->fading_paths);

  /* --- Populate channel_desc_t --- */
  chan_desc->nb_taps = (uint8_t)total_paths;
  chan_desc->channel_length = (uint8_t)fir_length;
  chan_desc->Td = rfsim_folded ? 0.0 : (double)(max_ds - min_ds) / fs_hz * 1e6;
  chan_desc->ricean_factor = 1.0;
  chan_desc->aoa = 0.0;
  chan_desc->random_aoa = 0;
  chan_desc->first_run = 0;
  chan_desc->ip = 0.0;
  chan_desc->channel_offset = 0;

  chan_desc->amps = calloc(total_paths, sizeof(double));
  chan_desc->free_flags |= CHANMODEL_FREE_AMPS;
  double total_amp = 0.0;
  chan_desc->amps[0] = cabs(los_phasor);
  total_amp += chan_desc->amps[0];
  for (int i = 0; i < n_reflectors; i++) {
    chan_desc->amps[1 + i] = cabs(ref_paths[i].phasor);
    total_amp += chan_desc->amps[1 + i];
  }
  if (total_amp > 0) {
    for (int i = 0; i < total_paths; i++)
      chan_desc->amps[i] /= total_amp;
  }

  chan_desc->delays = calloc(total_paths, sizeof(double));
  chan_desc->free_flags |= CHANMODEL_FREE_DELAY;
  chan_desc->delays[0] = los_delay * 1e6;
  for (int i = 0; i < n_reflectors; i++)
    chan_desc->delays[1 + i] = ref_paths[i].delay_s * 1e6;

  chan_desc->a = calloc(total_paths, sizeof(struct complexd *));
  for (int i = 0; i < total_paths; i++)
    chan_desc->a[i] = calloc(nb_tx * nb_rx, sizeof(struct complexd));

  chan_desc->ch = calloc(nb_tx * nb_rx, sizeof(struct complexd *));
  for (int i = 0; i < nb_tx * nb_rx; i++) {
    chan_desc->ch[i] = calloc(fir_length, sizeof(struct complexd));
    for (int k = 0; k < fir_length; k++) {
      chan_desc->ch[i][k].r = creal(fir[k]);
      chan_desc->ch[i][k].i = cimag(fir[k]);
    }
  }

  chan_desc->chF = calloc(nb_tx * nb_rx, sizeof(struct complexd *));
  for (int i = 0; i < nb_tx * nb_rx; i++)
    chan_desc->chF[i] = calloc(275 * 12, sizeof(struct complexd));

  chan_desc->R_sqrt = calloc(total_paths, sizeof(struct complexd *));
  chan_desc->free_flags |= CHANMODEL_FREE_RSQRT_NTAPS;
  for (int i = 0; i < total_paths; i++) {
    chan_desc->R_sqrt[i] = calloc(nb_tx * nb_rx * nb_tx * nb_rx, sizeof(struct complexd));
    for (int j = 0; j < nb_tx * nb_rx * nb_tx * nb_rx; j += (nb_tx * nb_rx + 1))
      chan_desc->R_sqrt[i][j].r = 1.0;
  }

  chan_desc->nb_paths = 10;
  free(fir);

  double ch_power = 0.0;
  for (int k = 0; k < fir_length; k++)
    ch_power += chan_desc->ch[0][k].r * chan_desc->ch[0][k].r
              + chan_desc->ch[0][k].i * chan_desc->ch[0][k].i;

  LOG_I(OCM, "[BICTR] Channel ready: nb_taps=%d channel_length=%d Td=%.3f us "
             "offset=%d total_ch_power=%.6f\n",
        chan_desc->nb_taps, chan_desc->channel_length, chan_desc->Td,
        chan_desc->channel_offset, ch_power);
}

/* ------------------------------------------------------------------ */
/*  Public entry point                                                 */
/* ------------------------------------------------------------------ */

void bictr_init_channel(channel_desc_t *chan_desc, const bictr_config_t *cfg)
{
  bictr_free_placeholder(chan_desc);

  const double fs_hz = chan_desc->sampling_rate;
  const double carrier_hz = (chan_desc->center_freq > 0)
                                ? (double)chan_desc->center_freq
                                : 3619200000.0;

  int use_terrain = (cfg->dem_file[0] != '\0');

  if (use_terrain) {
    /* ===== DEM terrain mode ===== */
    bictr_dem_t dem;
    memset(&dem, 0, sizeof(dem));

    if (bictr_dem_load(&dem, cfg->dem_file) != 0) {
      LOG_W(OCM, "[BICTR] DEM load failed, falling back to flat terrain\n");
      use_terrain = 0;
    }

    if (use_terrain) {
      double body_r = cfg->body_radius;

      /* Ground heights at TX and RX from DEM */
      double tx_ground = bictr_dem_get_height(&dem, cfg->tx_lon, cfg->tx_lat);
      double rx_ground = bictr_dem_get_height(&dem, cfg->rx_lon, cfg->rx_lat);

      /* 3D positions of TX and RX (on terrain + antenna height) */
      double tx_3d[3], rx_3d[3];
      geo_to_3d(body_r, cfg->tx_lon, cfg->tx_lat, tx_ground + cfg->tx_height,
                &tx_3d[0], &tx_3d[1], &tx_3d[2]);
      geo_to_3d(body_r, cfg->rx_lon, cfg->rx_lat, rx_ground + cfg->rx_height,
                &rx_3d[0], &rx_3d[1], &rx_3d[2]);

      double los_dist = dist3d(tx_3d[0], tx_3d[1], tx_3d[2],
                               rx_3d[0], rx_3d[1], rx_3d[2]);
      double los_delay = los_dist / SPEED_OF_LIGHT;

      LOG_I(OCM, "[BICTR] DEM terrain mode: TX (%.4f,%.4f) h=%.1f+%.1f  "
                 "RX (%.4f,%.4f) h=%.1f+%.1f  dist=%.1fm\n",
            cfg->tx_lon, cfg->tx_lat, tx_ground, cfg->tx_height,
            cfg->rx_lon, cfg->rx_lat, rx_ground, cfg->rx_height,
            los_dist);

      /* LOS phasor (check terrain LOS between TX and RX) */
      int has_los = dem_check_los(&dem, body_r,
                                  cfg->tx_lon, cfg->tx_lat, cfg->tx_height,
                                  cfg->rx_lon, cfg->rx_lat, cfg->rx_height);
      double los_pl = free_space_pathloss_amplitude(carrier_hz, los_dist);
      double complex los_phasor = has_los ? los_pl : 0.0;

      if (!has_los)
        LOG_W(OCM, "[BICTR] Direct TX-RX LOS blocked by terrain!\n");

      /* Reflector paths with terrain-aware placement */
      bictr_path_t ref_paths[255];
      int n_reflectors = 0;
      generate_reflectors_terrain(cfg, &dem, fs_hz, carrier_hz, los_dist,
                                  tx_3d, rx_3d,
                                  ref_paths, &n_reflectors, 254);

      LOG_I(OCM, "[BICTR] Terrain reflectors: %d found (LOS %s)\n",
            n_reflectors, has_los ? "YES" : "BLOCKED");

      /* Handle case where we have no paths at all */
      if (!has_los && n_reflectors == 0) {
        LOG_W(OCM, "[BICTR] No paths available — forcing unit LOS for stability\n");
        los_phasor = los_pl;
      }

      build_channel_fir(chan_desc, cfg, los_delay, los_phasor,
                        ref_paths, n_reflectors, fs_hz, carrier_hz);

      bictr_dem_free(&dem);
      return;
    }
  }

  /* ===== Flat terrain fallback ===== */
  LOG_I(OCM, "[BICTR] Flat terrain mode: dist=%.1fm txH=%.1fm rxH=%.1fm refCount=%d "
             "rings=%d attempts=%d rMin=%.0f rMax=%.0f fs=%.0f Hz carrier=%.0f Hz\n",
        cfg->tx_rx_dist, cfg->tx_height, cfg->rx_height, cfg->ref_count,
        cfg->ring_count, cfg->ref_attempt_per_ring,
        cfg->ring_radius_min, cfg->ring_radius_max,
        fs_hz, carrier_hz);

  double dx = cfg->tx_rx_dist;
  double dz = cfg->tx_height - cfg->rx_height;
  double los_dist = sqrt(dx * dx + dz * dz);
  double los_delay = los_dist / SPEED_OF_LIGHT;
  double los_pl = free_space_pathloss_amplitude(carrier_hz, los_dist);
  double complex los_phasor = los_pl;

  bictr_path_t ref_paths[255];
  int n_reflectors = 0;
  generate_reflectors_flat(cfg, fs_hz, carrier_hz, los_dist, los_pl,
                           ref_paths, &n_reflectors, 254);

  LOG_I(OCM, "[BICTR] Found %d reflectors, total paths=%d\n",
        n_reflectors, 1 + n_reflectors);

  build_channel_fir(chan_desc, cfg, los_delay, los_phasor,
                    ref_paths, n_reflectors, fs_hz, carrier_hz);
}
