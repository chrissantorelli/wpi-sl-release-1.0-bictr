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
 * This is a flat-terrain stub for first bring-up: all LOS checks pass,
 * reflector heights are 0. The model still produces frequency-selective
 * multipath from reflector geometry and Fresnel coefficients.
 */

#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <complex.h>

#include "bictr_channel.h"
#include "sim.h"
#include "common/utils/LOG/log.h"
#include "assertions.h"

#define SPEED_OF_LIGHT 299792458.0

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

/*
 * Flat-terrain reflector placement: TX at origin (0,0,txH), RX at (d,0,rxH).
 * Reflector placed at random angle/radius from the RX position on the ground
 * plane (z=0). Distance computed in 3D.
 */
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

      /* Reflection angle via law of cosines (thesis Eq. 10) */
      double cos_full = (dist_tx_ref * dist_tx_ref + dist_ref_rx * dist_ref_rx - los_dist * los_dist)
                        / (2.0 * dist_tx_ref * dist_ref_rx);
      if (cos_full > 1.0) cos_full = 1.0;
      if (cos_full < -1.0) cos_full = -1.0;
      double reflect_angle = (M_PI - acos(cos_full)) / 2.0;

      /* Complex relative permittivity with randomized real/imag parts */
      double eps_r = gaussZiggurat(cfg->permit_real, cfg->permit_real_std);
      double eps_i = gaussZiggurat(cfg->permit_imag, cfg->permit_imag_std);
      double complex eps_g = eps_r + I * (-eps_i);

      /* Reflection coefficient (thesis Eqs. 8-9) */
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

/*
 * Rayleigh fading via Zheng-Xiao model (thesis Eqs. 12-16).
 * Generates `length` complex samples and writes them to `out`.
 */
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

  /* Normalize: scale by 2/sqrt(M), then normalize to unit average power */
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

void bictr_init_channel(channel_desc_t *chan_desc, const bictr_config_t *cfg)
{
  bictr_free_placeholder(chan_desc);

  const int nb_tx = chan_desc->nb_tx;
  const int nb_rx = chan_desc->nb_rx;
  const double fs_hz = chan_desc->sampling_rate;
  const double carrier_hz = (chan_desc->center_freq > 0) ? (double)chan_desc->center_freq : 3619200000.0;

  LOG_I(OCM, "[BICTR] Initializing: dist=%.1fm txH=%.1fm rxH=%.1fm refCount=%d "
             "rings=%d attempts=%d rMin=%.0f rMax=%.0f fs=%.0f Hz carrier=%.0f Hz\n",
        cfg->tx_rx_dist, cfg->tx_height, cfg->rx_height, cfg->ref_count,
        cfg->ring_count, cfg->ref_attempt_per_ring,
        cfg->ring_radius_min, cfg->ring_radius_max,
        fs_hz, carrier_hz);

  /* --- LOS path --- */
  double dx = cfg->tx_rx_dist;
  double dz = cfg->tx_height - cfg->rx_height;
  double los_dist = sqrt(dx * dx + dz * dz);
  double los_delay = los_dist / SPEED_OF_LIGHT;
  double los_pl = free_space_pathloss_amplitude(carrier_hz, los_dist);

  /* LOS phasor: real-valued path-loss amplitude.
   * Hao's Python applies an additional exp(-j*2π*fc*τ_los) here, but that is
   * a constant phase offset absorbed by the receiver's channel estimator.
   * The physically important differential phase between taps is applied
   * later via the per-tap baseband rotation exp(-j*2π*fc*k/fs). */
  double complex los_phasor = los_pl;

  /* --- Reflector paths --- */
  bictr_path_t ref_paths[255];
  int n_reflectors = 0;
  generate_reflectors_flat(cfg, fs_hz, carrier_hz, los_dist, los_pl,
                           ref_paths, &n_reflectors, 254);

  int total_paths = 1 + n_reflectors;
  LOG_I(OCM, "[BICTR] Found %d reflectors, total paths=%d\n", n_reflectors, total_paths);

  /* Collect all delay samples relative to earliest path */
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
  if (fir_length > 250) {
    LOG_W(OCM, "[BICTR] FIR length %d exceeds uint8_t max, clamping to 250\n", fir_length);
    fir_length = 250;
  }

  /* --- Build FIR coefficient array (complex, baseband equivalent) --- */
  double complex *fir = calloc(fir_length, sizeof(double complex));
  AssertFatal(fir != NULL, "[BICTR] Failed to allocate FIR array\n");

  /* LOS tap — real-valued, placed at its relative sample index */
  int los_idx = all_delay_samp[0] - min_ds;
  if (los_idx >= 0 && los_idx < fir_length)
    fir[los_idx] += los_phasor;

  /* Reflector taps — complex gain from Fresnel + random scattering phase,
   * NO carrier-frequency phase rotation */
  for (int i = 0; i < n_reflectors; i++) {
    int idx = all_delay_samp[1 + i] - min_ds;
    if (idx >= 0 && idx < fir_length)
      fir[idx] += ref_paths[i].phasor;
  }

  /* --- Rayleigh fading component --- */
  if (cfg->fading_paths > 0 && fir_length > 0) {
    double complex *fading = calloc(fir_length, sizeof(double complex));
    AssertFatal(fading != NULL, "[BICTR] Failed to allocate fading array\n");

    generate_rayleigh_fading(cfg->fading_paths, cfg->doppler_spread,
                             carrier_hz, fs_hz, fir_length, fading);

    double fading_scale = los_pl / fir_length;
    for (int t = 0; t < fir_length; t++)
      fading[t] *= fading_scale;

    for (int t = 0; t < fir_length; t++)
      fir[t] += fading[t];

    free(fading);
  }

  /* Normalize by (refCount + 1) as per thesis Eq. 6 */
  double norm_factor = 1.0 / (cfg->ref_count + 1);
  for (int t = 0; t < fir_length; t++)
    fir[t] *= norm_factor;

  /* Baseband differential phase rotation (thesis baseband conversion).
   * Each tap at index k gets exp(-j * 2π * fc * k / fs), encoding the
   * carrier-frequency dependent phase shift between taps at different delays.
   * This produces the correct frequency-selective fading pattern. */
  for (int k = 0; k < fir_length; k++) {
    double phase = -2.0 * M_PI * carrier_hz * (double)k / fs_hz;
    fir[k] *= cexp(I * phase);
  }

  /* Normalize FIR to unit total energy — OAI convention.
   * Physical path loss is controlled separately via ploss_dB in the config. */
  double raw_energy = 0.0;
  for (int t = 0; t < fir_length; t++)
    raw_energy += creal(fir[t]) * creal(fir[t]) + cimag(fir[t]) * cimag(fir[t]);

  if (raw_energy > 1e-30) {
    double scale = 1.0 / sqrt(raw_energy);
    for (int t = 0; t < fir_length; t++)
      fir[t] *= scale;
    LOG_I(OCM, "[BICTR] FIR normalized: raw_energy=%.6e scale=%.6e\n", raw_energy, scale);
  } else {
    LOG_W(OCM, "[BICTR] FIR energy is zero — falling back to single unit tap\n");
    fir[0] = 1.0;
  }

  /* --- Populate channel_desc_t --- */
  chan_desc->nb_taps = (uint8_t)total_paths;
  chan_desc->channel_length = (uint8_t)fir_length;
  chan_desc->Td = (double)(max_ds - min_ds) / fs_hz * 1e6;
  chan_desc->ricean_factor = 1.0;
  chan_desc->aoa = 0.0;
  chan_desc->random_aoa = 0;
  chan_desc->first_run = 0;
  chan_desc->ip = 0.0;
  chan_desc->channel_offset = 0;

  /* amps: power of each FIR tap (used for display only since we write ch directly) */
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

  /* delays: in microseconds */
  chan_desc->delays = calloc(total_paths, sizeof(double));
  chan_desc->free_flags |= CHANMODEL_FREE_DELAY;
  chan_desc->delays[0] = los_delay * 1e6;
  for (int i = 0; i < n_reflectors; i++)
    chan_desc->delays[1 + i] = ref_paths[i].delay_s * 1e6;

  /* a[tap][ant_pair]: tap coefficients — set to identity-like for display purposes */
  chan_desc->a = calloc(total_paths, sizeof(struct complexd *));
  for (int i = 0; i < total_paths; i++)
    chan_desc->a[i] = calloc(nb_tx * nb_rx, sizeof(struct complexd));

  /* ch[ant_pair][k]: the interpolated impulse response — this is what rxAddInput() uses */
  chan_desc->ch = calloc(nb_tx * nb_rx, sizeof(struct complexd *));
  for (int i = 0; i < nb_tx * nb_rx; i++) {
    chan_desc->ch[i] = calloc(fir_length, sizeof(struct complexd));
    for (int k = 0; k < fir_length; k++) {
      chan_desc->ch[i][k].r = creal(fir[k]);
      chan_desc->ch[i][k].i = cimag(fir[k]);
    }
  }

  /* chF: frequency-domain (allocated but zeroed — not used by rxAddInput) */
  chan_desc->chF = calloc(nb_tx * nb_rx, sizeof(struct complexd *));
  for (int i = 0; i < nb_tx * nb_rx; i++)
    chan_desc->chF[i] = calloc(275 * 12, sizeof(struct complexd));

  /* R_sqrt: identity correlation matrix (SISO typical) */
  chan_desc->R_sqrt = calloc(total_paths, sizeof(struct complexd *));
  chan_desc->free_flags |= CHANMODEL_FREE_RSQRT_NTAPS;
  for (int i = 0; i < total_paths; i++) {
    chan_desc->R_sqrt[i] = calloc(nb_tx * nb_rx * nb_tx * nb_rx, sizeof(struct complexd));
    for (int j = 0; j < nb_tx * nb_rx * nb_tx * nb_rx; j += (nb_tx * nb_rx + 1))
      chan_desc->R_sqrt[i][j].r = 1.0;
  }

  chan_desc->nb_paths = 10;

  free(fir);

  /* Log channel power for sanity */
  double ch_power = 0.0;
  for (int k = 0; k < fir_length; k++)
    ch_power += chan_desc->ch[0][k].r * chan_desc->ch[0][k].r
              + chan_desc->ch[0][k].i * chan_desc->ch[0][k].i;

  LOG_I(OCM, "[BICTR] Channel ready: nb_taps=%d channel_length=%d Td=%.3f us "
             "offset=%d total_ch_power=%.6f\n",
        chan_desc->nb_taps, chan_desc->channel_length, chan_desc->Td,
        chan_desc->channel_offset, ch_power);
}
