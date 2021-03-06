﻿using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Web.UI.DataVisualization.Charting;
using MOE.Common.Business.WCFServiceLibrary;

namespace MOE.Common.Business
{
    public class DelayChart
    {
        public Chart chart = new Chart();


        public DelayChart(ApproachDelayOptions options, SignalPhase signalPhase)
        {
            Options = options;
            var reportTimespan = Options.EndDate - Options.StartDate;
            var extendedDirection = signalPhase.Approach.DirectionType.Description;
            //Set the chart properties
            ChartFactory.SetImageProperties(chart);


            //Create the chart legend
            var chartLegend = new Legend();
            chartLegend.Name = "MainLegend";
            chartLegend.Docking = Docking.Left;
            chart.Legends.Add(chartLegend);


            //Create the chart area
            var chartArea = new ChartArea();
            chartArea.Name = "ChartArea1";

            //Primary Y axis (delay per vehicle)
            if (Options.ShowDelayPerVehicle)
            {
                if (Options.YAxisMax != null)
                    chartArea.AxisY.Maximum = Options.YAxisMax.Value;
                chartArea.AxisY.Minimum = 0;
                chartArea.AxisY.Enabled = AxisEnabled.True;
                chartArea.AxisY.MajorTickMark.Enabled = true;
                chartArea.AxisY.MajorGrid.Enabled = true;
                chartArea.AxisY.Interval = 5;
                chartArea.AxisY.TitleForeColor = Color.Blue;
                chartArea.AxisY.Title = "Delay Per Vehicle (Seconds) ";
            }

            //secondary y axis (total delay)
            if (Options.ShowDelayPerVehicle)
            {
                if (Options.Y2AxisMax != null && Options.Y2AxisMax > 0)
                    chartArea.AxisY2.Maximum = Options.Y2AxisMax.Value;
                else
                    chartArea.AxisY2.Maximum = 10;
                chartArea.AxisY2.Minimum = 0;
                chartArea.AxisY2.Enabled = AxisEnabled.True;
                chartArea.AxisY2.MajorTickMark.Enabled = true;
                chartArea.AxisY2.MajorGrid.Enabled = false;
                chartArea.AxisY2.Interval = 5;
                chartArea.AxisY2.Title = "Delay per Hour (hrs) ";
                chartArea.AxisY2.TitleForeColor = Color.Red;
            }

            chartArea.AxisX.Title = "Time (Hour of Day)";
            chartArea.AxisX.IntervalType = DateTimeIntervalType.Hours;
            chartArea.AxisX.LabelStyle.Format = "HH";
            chartArea.AxisX2.LabelStyle.Format = "HH";
            if (reportTimespan.Days < 1)
                if (reportTimespan.Hours > 1)
                {
                    chartArea.AxisX2.Interval = 1;
                    chartArea.AxisX.Interval = 1;
                }
                else
                {
                    chartArea.AxisX.LabelStyle.Format = "HH:mm";
                    chartArea.AxisX2.LabelStyle.Format = "HH:mm";
                }
            chartArea.AxisX2.Enabled = AxisEnabled.True;
            chartArea.AxisX2.MajorTickMark.Enabled = true;
            chartArea.AxisX2.IntervalType = DateTimeIntervalType.Hours;
            chartArea.AxisX2.LabelAutoFitStyle = LabelAutoFitStyles.None;

            chart.ChartAreas.Add(chartArea);


            //Add the point series

            var delayPerVehicleSeries = new Series();
            delayPerVehicleSeries.ChartType = SeriesChartType.Line;
            delayPerVehicleSeries.Color = Color.Blue;
            delayPerVehicleSeries.Name = "Approach Delay Per Vehicle";
            delayPerVehicleSeries.YAxisType = AxisType.Primary;
            delayPerVehicleSeries.XValueType = ChartValueType.DateTime;

            var delaySeries = new Series();
            delaySeries.ChartType = SeriesChartType.Line;
            delaySeries.Color = Color.Red;
            delaySeries.Name = "Approach Delay";
            delaySeries.YAxisType = AxisType.Secondary;
            delaySeries.XValueType = ChartValueType.DateTime;


            var pointSeries = new Series();
            pointSeries.ChartType = SeriesChartType.Point;
            pointSeries.Color = Color.White;
            pointSeries.Name = "Posts";
            pointSeries.XValueType = ChartValueType.DateTime;
            pointSeries.IsVisibleInLegend = false;


            chart.Series.Add(pointSeries);
            chart.Series.Add(delaySeries);
            chart.Series.Add(delayPerVehicleSeries);


            //Add points at the start and and of the x axis to ensure
            //the graph covers the entire period selected by the user
            //whether there is data or not
            chart.Series["Posts"].Points.AddXY(Options.StartDate, 0);
            chart.Series["Posts"].Points.AddXY(Options.EndDate, 0);

            AddDataToChart(chart, signalPhase, Options.SelectedBinSize, Options.ShowTotalDelayPerHour,
                Options.ShowDelayPerVehicle);
            if (Options.ShowPlanStatistics)
                SetPlanStrips(signalPhase.Plans, chart, Options.StartDate, Options.ShowPlanStatistics);
        }

        public ApproachDelayOptions Options { get; set; }

        private void SetChartTitles(SignalPhase signalPhase, Dictionary<string, string> statistics)
        {
            chart.Titles.Add(ChartTitleFactory.GetChartName(Options.MetricTypeID));
            chart.Titles.Add(ChartTitleFactory.GetSignalLocationAndDateRange(
                Options.SignalID, Options.StartDate, Options.EndDate));
                chart.Titles.Add(ChartTitleFactory.GetPhaseAndPhaseDescriptions(
                    signalPhase.Approach, signalPhase.GetPermissivePhase));
            chart.Titles.Add(ChartTitleFactory.GetStatistics(statistics));
            chart.Titles.Add(ChartTitleFactory.GetTitle(
                "Simplified Approach Delay. Displays time between approach activation during the red phase and when the phase turns green."
                + " \n Does NOT account for start up delay, deceleration, or queue length that exceeds the detection zone."));
            chart.Titles.LastOrDefault().Docking = Docking.Bottom;
        }


        protected void AddDataToChart(Chart chart, SignalPhase signalPhase, int binSize, bool showDelayPerHour,
            bool showDelayPerVehicle)
        {
            var dt = signalPhase.StartDate;
            while (dt < signalPhase.EndDate)
            {
                var pcdsInBin = from item in signalPhase.Cycles
                    where item.StartTime >= dt && item.StartTime < dt.AddMinutes(binSize)
                    select item;

                var binDelay = pcdsInBin.Sum(d => d.TotalDelay);
                var binVolume = pcdsInBin.Sum(d => d.TotalVolume);
                double bindDelaypervehicle = 0;
                double bindDelayperhour = 0;

                if (binVolume > 0 && pcdsInBin.Any())
                    bindDelaypervehicle = binDelay / binVolume;
                else
                    bindDelaypervehicle = 0;

                bindDelayperhour = binDelay * (60 / binSize) /60/60;

                if (showDelayPerVehicle)
                    chart.Series["Approach Delay Per Vehicle"].Points.AddXY(dt, bindDelaypervehicle);
                if (showDelayPerHour)
                    chart.Series["Approach Delay"].Points.AddXY(dt, bindDelayperhour);

                dt = dt.AddMinutes(binSize);
            }
            var statistics = new Dictionary<string, string>();
            statistics.Add("Average Delay Per Vehicle (AD)", Math.Round(signalPhase.AvgDelay) + " seconds");
            statistics.Add("Total Delay For Selected Period (TD)", Math.Round(signalPhase.TotalDelay/60/60,1) + " hours");
            SetChartTitles(signalPhase, statistics);
        }


        protected void SetPlanStrips(List<PlanPcd> planCollection, Chart chart, DateTime graphStartDate,
            bool showPlanStatistics)
        {
            var backGroundColor = 1;
            foreach (var plan in planCollection)
            {
                var stripline = new StripLine();
                //Creates alternating backcolor to distinguish the plans
                if (backGroundColor % 2 == 0)
                    stripline.BackColor = Color.FromArgb(120, Color.LightGray);
                else
                    stripline.BackColor = Color.FromArgb(120, Color.LightBlue);

                //Set the stripline properties
                stripline.IntervalOffsetType = DateTimeIntervalType.Hours;
                stripline.Interval = 1;
                stripline.IntervalOffset = (plan.StartTime - graphStartDate).TotalHours;
                stripline.StripWidth = (plan.EndTime - plan.StartTime).TotalHours;
                stripline.StripWidthType = DateTimeIntervalType.Hours;

                chart.ChartAreas["ChartArea1"].AxisX.StripLines.Add(stripline);

                //Add a corrisponding custom label for each strip
                var Plannumberlabel = new CustomLabel();
                Plannumberlabel.FromPosition = plan.StartTime.ToOADate();
                Plannumberlabel.ToPosition = plan.EndTime.ToOADate();
                switch (plan.PlanNumber)
                {
                    case 254:
                        Plannumberlabel.Text = "Free";
                        break;
                    case 255:
                        Plannumberlabel.Text = "Flash";
                        break;
                    case 0:
                        Plannumberlabel.Text = "Unknown";
                        break;
                    default:
                        Plannumberlabel.Text = "Plan " + plan.PlanNumber;

                        break;
                }

                Plannumberlabel.ForeColor = Color.Black;
                Plannumberlabel.RowIndex = 3;

                chart.ChartAreas["ChartArea1"].AxisX2.CustomLabels.Add(Plannumberlabel);


                var avgDelay = Math.Round(plan.AvgDelay, 0);
                var totalDelay = Math.Round(plan.TotalDelay);

                if (showPlanStatistics)
                {
                    var aogLabel = new CustomLabel();
                    aogLabel.FromPosition = plan.StartTime.ToOADate();
                    aogLabel.ToPosition = plan.EndTime.ToOADate();
                    aogLabel.Text = Math.Round(totalDelay / 60 /60, 1) + " TD";
                    aogLabel.LabelMark = LabelMarkStyle.LineSideMark;
                    aogLabel.ForeColor = Color.Red;
                    aogLabel.RowIndex = 1;
                    chart.ChartAreas["ChartArea1"].AxisX2.CustomLabels.Add(aogLabel);

                    var statisticlabel = new CustomLabel();
                    statisticlabel.FromPosition = plan.StartTime.ToOADate();
                    statisticlabel.ToPosition = plan.EndTime.ToOADate();
                    //statisticlabel.LabelMark = LabelMarkStyle.LineSideMark;
                    statisticlabel.Text = avgDelay + " AD\n";
                    statisticlabel.ForeColor = Color.Blue;
                    statisticlabel.RowIndex = 2;
                    chart.ChartAreas["ChartArea1"].AxisX2.CustomLabels.Add(statisticlabel);
                }
                //Change the background color counter for alternating color
                backGroundColor++;
            }
        }
    }
}