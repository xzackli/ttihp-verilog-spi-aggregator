  /*
  * Copyright (c) 2026 Zack Li
  * SPDX-License-Identifier: Apache-2.0
  */

  `default_nettype none

// SPI mode 0 timing has peripherals guarantee valid data on falling edge of SCLK, 
// and reading occurs on the subsequent rising edge.

  module tt_um_spi_aggregator (
      input  wire [7:0] ui_in,    // Dedicated inputs
      output wire [7:0] uo_out,   // Dedicated outputs
      input  wire [7:0] uio_in,   // IOs: Input path
      output wire [7:0] uio_out,  // IOs: Output path
      output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
      input  wire       ena,      // always 1 when the design is powered, so you can ignore it
      input  wire       clk,      // clock
      input  wire       rst_n     // reset_n - low to reset
  );

    // All output pins must be assigned. If not used, assign to 0.
    assign uio_oe  = 8'b01110000;  // msb to lsb 7:0 of bidi (uio[7] is input for config)

    // List all unused inputs to prevent warnings
    wire _unused = &{ena, uio_in[7:4], 1'b0};
    assign uio_out[7] = 0;  // directly from input
    assign uio_out[3:0] = 0; // unused

    // decode the configuration wires and calculate derived parameters
    // cfg_adc_bits: 4 pins (ui_in[3:0]) + 1 = 1-16 bits
    wire [4:0] cfg_adc_bits = ui_in[3:0] + 1;
    wire [1:0] cfg_adc_null = ui_in[5:4];
    wire [1:0] cfg_clk_div  = ui_in[7:6];
    wire [5:0] cfg_adc_cycles = {1'b0, cfg_adc_bits} + {4'd0, cfg_adc_null};  // total ADC read clocks
    wire [6:0] cfg_tx_bits = {2'b0, cfg_adc_bits} * 4; // total TX clocks for 4 ADCs (up to 64)
    // clock divider: 0->4, 1->8, 2->12, 3->16 (half-period counts: 1, 3, 5, 7)
    // SCLK period = (cfg_clk_max + 1) * 2 * T_clk
    wire [3:0] cfg_clk_max = (cfg_clk_div * 2) + 1;

    reg [5:0] cycle; // current cycle within ADC read phase
    reg [6:0] tx_cycle; // current cycle within TX phase (up to 64)
    reg adc_sclk; // ADC serial clock (divided)
    reg [3:0] clk_div;
    wire adc_cs_n; // ADC chip select (active low)
    wire tx_mosi;
    wire tx_sclk;
    wire tx_cs_n;
    
    // clock fanout
    assign uo_out[0] = adc_sclk;
    assign uo_out[2] = adc_sclk;
    assign uo_out[6] = adc_sclk;
    assign uio_out[4] = adc_sclk;

    // chip select fanout
    assign uo_out[1] = adc_cs_n;
    assign uio_out[5] = adc_cs_n;

    assign uo_out[3] = tx_mosi;
    assign uo_out[4] = tx_sclk;
    assign uo_out[5] = tx_cs_n;
    assign uo_out[7] = tx_cs_n;
    assign uio_out[6] = tx_cs_n;

    reg [15:0] adc_data0, adc_data1, adc_data2, adc_data3; // shift registers for ADC data (up to 16 bits)
    wire adc_phase = (cycle < cfg_adc_cycles);  // ADC sampling phase
    wire tx_phase = !adc_phase && (tx_cycle < cfg_tx_bits);  // TX phase (full speed)
    assign adc_cs_n = !adc_phase; // active low during adc sampling phase
    wire adc_capture = adc_phase && (cycle >= {4'd0, cfg_adc_null}); // capture data after null bits
    assign tx_cs_n = !tx_phase; // active low during tx phase
    assign tx_sclk = clk; // TX runs at full system clock speed
    
    // Compute which ADC register to transmit from based on tx_cycle
    wire [6:0] tx_boundary1 = {2'b0, cfg_adc_bits};
    wire [6:0] tx_boundary2 = {2'b0, cfg_adc_bits} * 2;
    wire [6:0] tx_boundary3 = {2'b0, cfg_adc_bits} * 3;
    wire [1:0] tx_adc_sel = (tx_cycle < tx_boundary1) ? 2'd0 :
                            (tx_cycle < tx_boundary2) ? 2'd1 :
                            (tx_cycle < tx_boundary3) ? 2'd2 : 2'd3;
    
    // Look ahead to the next cycle to decide if we should shift the same ADC
    wire [6:0] tx_cycle_next = tx_cycle + 1;
    wire [1:0] tx_adc_sel_next = (tx_cycle_next < tx_boundary1) ? 2'd0 :
                   (tx_cycle_next < tx_boundary2) ? 2'd1 :
                   (tx_cycle_next < tx_boundary3) ? 2'd2 : 2'd3;
    
    // Mux to select MSB of current ADC register for TX output
    assign tx_mosi = (tx_adc_sel == 2'd0) ? adc_data0[15] :
                     (tx_adc_sel == 2'd1) ? adc_data1[15] :
                     (tx_adc_sel == 2'd2) ? adc_data2[15] : adc_data3[15];

    always @(posedge clk) begin  // flip-flop logic
      if (!rst_n) begin  // reset is active low
        clk_div <= 0;
        adc_sclk <= 0;
        cycle <= 0;
        tx_cycle <= 0;
        adc_data0 <= 0;
        adc_data1 <= 0;
        adc_data2 <= 0;
        adc_data3 <= 0;
      end else if (adc_phase) begin
        // ADC phase: run at divided clock
        if (clk_div == cfg_clk_max) begin
          clk_div <= 0;
          adc_sclk <= ~adc_sclk;
          
          // Rising edge: capture ADC data (after cycle has advanced)
          if (!adc_sclk && adc_capture) begin
            adc_data0 <= {adc_data0[14:0], uio_in[0]};
            adc_data1 <= {adc_data1[14:0], uio_in[1]};
            adc_data2 <= {adc_data2[14:0], uio_in[2]};
            adc_data3 <= {adc_data3[14:0], uio_in[3]};
          end

          // Falling edge: advance cycle counter
          if (adc_sclk) begin
            if (cycle == cfg_adc_cycles - 1) begin
              // End of ADC phase: left-justify data in 16-bit registers for TX
              adc_data0 <= adc_data0 << (16 - cfg_adc_bits);
              adc_data1 <= adc_data1 << (16 - cfg_adc_bits);
              adc_data2 <= adc_data2 << (16 - cfg_adc_bits);
              adc_data3 <= adc_data3 << (16 - cfg_adc_bits);
              tx_cycle <= 0;
            end
            cycle <= cycle + 1;
          end
        end else begin
          clk_div <= clk_div + 1;
        end
      end else if (tx_phase) begin
        // TX phase: shift the currently selected ADC in preparation for the next bit,
        // but only if the next cycle is still within TX and stays on the same ADC.
        if (tx_cycle < cfg_tx_bits - 1 && tx_adc_sel_next == tx_adc_sel) begin
          case (tx_adc_sel)
            2'd0: adc_data0 <= {adc_data0[14:0], 1'b0};
            2'd1: adc_data1 <= {adc_data1[14:0], 1'b0};
            2'd2: adc_data2 <= {adc_data2[14:0], 1'b0};
            2'd3: adc_data3 <= {adc_data3[14:0], 1'b0};
            default: ;
          endcase
        end
        tx_cycle <= tx_cycle + 1;
      end else begin
        // End of TX phase: reset for next ADC cycle
        cycle <= 0;
        tx_cycle <= 0;
        clk_div <= 0;
        adc_sclk <= 0;
      end
    end


  endmodule
