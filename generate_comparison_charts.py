#!/usr/bin/env python3
"""
Professional Performance Analysis Tool - PostgreSQL vs Citus
Developed for Graduate Thesis

This script reads PostgreSQL and Citus benchmark results and generates
professional comparative performance charts (TPS, Latency) for academic analysis.
"""

import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
import numpy as np
import os
from pathlib import Path
import argparse
from datetime import datetime

# Configure professional chart styling
plt.style.use('seaborn-v0_8-whitegrid')
colors_palette = ['#2E86AB', '#A23B72', '#F18F01', '#C73E1D']
sns.set_palette(colors_palette)
plt.rcParams['figure.figsize'] = (14, 8)
plt.rcParams['font.size'] = 12
plt.rcParams['font.family'] = 'DejaVu Sans'
plt.rcParams['axes.grid'] = True
plt.rcParams['grid.alpha'] = 0.4
plt.rcParams['axes.edgecolor'] = '#333333'
plt.rcParams['axes.linewidth'] = 1.2

class BenchmarkAnalyzer:
    def __init__(self, base_dir=None):
        """Initialize benchmark analyzer"""
        if base_dir is None:
            base_dir = Path(__file__).parent
        else:
            base_dir = Path(base_dir)
            
        self.base_dir = base_dir
        self.postgresql_csv = base_dir / "postgre" / "benchmark_universal" / "latest_reports" / "benchmark_results.csv"
        self.citus_csv = base_dir / "citus" / "benchmark_universal" / "latest_reports" / "benchmark_results.csv"
        self.output_dir = base_dir / "comparison_charts"
        
        # Create output directory
        self.output_dir.mkdir(exist_ok=True)
        
        print(f"📊 Benchmark Analyzer Initialized")
        print(f"   • Base directory: {self.base_dir}")
        print(f"   • Output directory: {self.output_dir}")
        
    def load_data(self):
        """Load data from CSV files"""
        print("\n📂 Loading data...")
        
        # Check if files exist
        if not self.postgresql_csv.exists():
            raise FileNotFoundError(f"PostgreSQL CSV not found: {self.postgresql_csv}")
        if not self.citus_csv.exists():
            raise FileNotFoundError(f"Citus CSV not found: {self.citus_csv}")
            
        # Load data
        try:
            pg_data = pd.read_csv(self.postgresql_csv)
            citus_data = pd.read_csv(self.citus_csv)
            
            print(f"   ✅ PostgreSQL: {len(pg_data)} records")
            print(f"   ✅ Citus: {len(citus_data)} records")
            
            # Combine data
            combined_data = pd.concat([pg_data, citus_data], ignore_index=True)
            
            # Convert data types
            combined_data['TPS'] = pd.to_numeric(combined_data['TPS'], errors='coerce')
            combined_data['Latency_Avg_ms'] = pd.to_numeric(combined_data['Latency_Avg_ms'], errors='coerce')
            combined_data['Clients'] = pd.to_numeric(combined_data['Clients'], errors='coerce')
            
            # Remove invalid data
            combined_data = combined_data.dropna(subset=['TPS', 'Latency_Avg_ms'])
            
            print(f"   📊 Total combined: {len(combined_data)} valid records")
            print(f"   📈 Workloads: {sorted(combined_data['Suite'].unique())}")
            print(f"   👥 Client configurations: {sorted(combined_data['Clients'].unique())}")
            
            return combined_data
            
        except Exception as e:
            raise Exception(f"Error loading data: {e}")
    
    def calculate_statistics(self, data):
        """Calculate aggregated statistics"""
        print("\n📈 Calculating statistics...")
        
        # Group by Database_Type, Suite and Clients, calculate means
        stats = data.groupby(['Database_Type', 'Suite', 'Clients']).agg({
            'TPS': ['mean', 'std', 'min', 'max'],
            'Latency_Avg_ms': ['mean', 'std', 'min', 'max'],
            'Run': 'count'
        }).reset_index()
        
        # Flatten multi-level columns
        stats.columns = [
            'Database_Type', 'Suite', 'Clients',
            'TPS_mean', 'TPS_std', 'TPS_min', 'TPS_max',
            'Latency_mean', 'Latency_std', 'Latency_min', 'Latency_max',
            'Run_count'
        ]
        
        # Fill NaN in standard deviation with 0
        stats['TPS_std'] = stats['TPS_std'].fillna(0)
        stats['Latency_std'] = stats['Latency_std'].fillna(0)
        
        print(f"   📊 Statistics calculated for {len(stats)} configurations")
        
        return stats
    
    def create_tps_comparison(self, stats):
        """Generate TPS comparison chart"""
        print("\n🚀 Generating TPS comparison chart...")
        
        suites = sorted(stats['Suite'].unique())
        n_suites = len(suites)
        
        # Adjust layout based on number of workloads
        if n_suites == 1:
            fig, axes = plt.subplots(1, 1, figsize=(10, 7))
            axes = [axes]  # Convert to list for compatibility
        elif n_suites == 2:
            fig, axes = plt.subplots(1, 2, figsize=(15, 7))
        else:
            fig, axes = plt.subplots(1, n_suites, figsize=(7*n_suites, 7))
            
        fig.suptitle('Performance Comparison: Transactions Per Second (TPS)\nPostgreSQL vs Citus', 
                     fontsize=18, fontweight='bold', y=0.95)
        
        colors = ['#2E86AB', '#F18F01']  # Professional blue for PostgreSQL, Orange for Citus
        
        for idx, suite in enumerate(suites):
            ax = axes[idx]
            suite_data = stats[stats['Suite'] == suite]
            
            # Data by database type
            pg_data = suite_data[suite_data['Database_Type'] == 'postgresql']
            citus_data = suite_data[suite_data['Database_Type'] == 'citus']
            
            x = np.arange(len(pg_data))
            width = 0.35
            
            # Create bars with professional styling
            bars1 = ax.bar(x - width/2, pg_data['TPS_mean'], width, 
                          yerr=pg_data['TPS_std'], label='PostgreSQL', 
                          color=colors[0], alpha=0.85, capsize=5, 
                          edgecolor='white', linewidth=1.5)
            bars2 = ax.bar(x + width/2, citus_data['TPS_mean'], width,
                          yerr=citus_data['TPS_std'], label='Citus',
                          color=colors[1], alpha=0.85, capsize=5,
                          edgecolor='white', linewidth=1.5)
            
            # Customize axes with professional styling
            ax.set_title(f'{suite.replace("_", " ").title()}', fontweight='bold', fontsize=14, pad=20)
            ax.set_xlabel('Number of Clients', fontweight='semibold')
            ax.set_ylabel('TPS (Transactions/sec)', fontweight='semibold')
            ax.set_xticks(x)
            ax.set_xticklabels(pg_data['Clients'].astype(int))
            ax.legend(frameon=True, fancybox=True, shadow=True)
            ax.grid(True, alpha=0.3, linestyle='-', linewidth=0.5)
            ax.set_axisbelow(True)
            
            # Add value labels on bars
            for bar in bars1:
                height = bar.get_height()
                ax.text(bar.get_x() + bar.get_width()/2., height + height*0.05,
                       f'{height:.0f}', ha='center', va='bottom', fontsize=10, fontweight='bold')
            
            for bar in bars2:
                height = bar.get_height()
                ax.text(bar.get_x() + bar.get_width()/2., height + height*0.05,
                       f'{height:.0f}', ha='center', va='bottom', fontsize=10, fontweight='bold')
        
        plt.tight_layout(rect=[0, 0.03, 1, 0.95])
        
        # Save with high quality
        tps_file = self.output_dir / "tps_comparison.png"
        plt.savefig(tps_file, dpi=300, bbox_inches='tight', facecolor='white', edgecolor='none')
        print(f"   💾 Saved: {tps_file}")
        
        return fig
    
    def create_latency_comparison(self, stats):
        """Generate latency comparison chart"""
        print("\n⏱️  Generating latency comparison chart...")
        
        suites = sorted(stats['Suite'].unique())
        n_suites = len(suites)
        
        # Adjust layout based on number of workloads
        if n_suites == 1:
            fig, axes = plt.subplots(1, 1, figsize=(10, 7))
            axes = [axes]
        elif n_suites == 2:
            fig, axes = plt.subplots(1, 2, figsize=(15, 7))
        else:
            fig, axes = plt.subplots(1, n_suites, figsize=(7*n_suites, 7))
            
        fig.suptitle('Latency Comparison: Average Response Time\nPostgreSQL vs Citus', 
                     fontsize=18, fontweight='bold', y=0.95)
        
        colors = ['#2E86AB', '#F18F01']
        
        for idx, suite in enumerate(suites):
            ax = axes[idx]
            suite_data = stats[stats['Suite'] == suite]
            
            # Data by database type
            pg_data = suite_data[suite_data['Database_Type'] == 'postgresql']
            citus_data = suite_data[suite_data['Database_Type'] == 'citus']
            
            x = np.arange(len(pg_data))
            width = 0.35
            
            # Create bars with professional styling
            bars1 = ax.bar(x - width/2, pg_data['Latency_mean'], width,
                          yerr=pg_data['Latency_std'], label='PostgreSQL',
                          color=colors[0], alpha=0.85, capsize=5,
                          edgecolor='white', linewidth=1.5)
            bars2 = ax.bar(x + width/2, citus_data['Latency_mean'], width,
                          yerr=citus_data['Latency_std'], label='Citus',
                          color=colors[1], alpha=0.85, capsize=5,
                          edgecolor='white', linewidth=1.5)
            
            # Customize axes with professional styling
            ax.set_title(f'{suite.replace("_", " ").title()}', fontweight='bold', fontsize=14, pad=20)
            ax.set_xlabel('Number of Clients', fontweight='semibold')
            ax.set_ylabel('Average Latency (ms)', fontweight='semibold')
            ax.set_xticks(x)
            ax.set_xticklabels(pg_data['Clients'].astype(int))
            ax.legend(frameon=True, fancybox=True, shadow=True)
            ax.grid(True, alpha=0.3, linestyle='-', linewidth=0.5)
            ax.set_axisbelow(True)
            
            # Add value labels on bars
            for bar in bars1:
                height = bar.get_height()
                ax.text(bar.get_x() + bar.get_width()/2., height + height*0.05,
                       f'{height:.1f}', ha='center', va='bottom', fontsize=10, fontweight='bold')
            
            for bar in bars2:
                height = bar.get_height()
                ax.text(bar.get_x() + bar.get_width()/2., height + height*0.05,
                       f'{height:.1f}', ha='center', va='bottom', fontsize=10, fontweight='bold')
        
        plt.tight_layout(rect=[0, 0.03, 1, 0.95])
        
        # Save with high quality
        latency_file = self.output_dir / "latency_comparison.png"
        plt.savefig(latency_file, dpi=300, bbox_inches='tight', facecolor='white', edgecolor='none')
        print(f"   💾 Saved: {latency_file}")
        
        return fig
    
    def create_throughput_vs_latency(self, stats):
        """Generate TPS vs Latency scatter plot"""
        print("\n📊 Generating TPS vs Latency scatter plot...")
        
        suites = sorted(stats['Suite'].unique())
        n_suites = len(suites)
        
        # Adjust layout based on number of workloads
        if n_suites == 1:
            fig, axes = plt.subplots(1, 1, figsize=(10, 7))
            axes = [axes]
        elif n_suites == 2:
            fig, axes = plt.subplots(1, 2, figsize=(15, 7))
        else:
            fig, axes = plt.subplots(1, n_suites, figsize=(7*n_suites, 7))
            
        fig.suptitle('Performance Trade-off: TPS vs Latency\nPostgreSQL vs Citus', 
                     fontsize=18, fontweight='bold', y=0.95)
        
        colors = {'postgresql': '#2E86AB', 'citus': '#F18F01'}
        markers = {'postgresql': 'o', 'citus': 's'}
        
        for idx, suite in enumerate(suites):
            ax = axes[idx]
            suite_data = stats[stats['Suite'] == suite]
            
            for db_type in ['postgresql', 'citus']:
                db_data = suite_data[suite_data['Database_Type'] == db_type]
                
                ax.scatter(db_data['Latency_mean'], db_data['TPS_mean'],
                          c=colors[db_type], marker=markers[db_type],
                          s=120, alpha=0.85, label=db_type.title(),
                          edgecolors='white', linewidth=2)
                
                # Add client labels
                for _, row in db_data.iterrows():
                    ax.annotate(f"{int(row['Clients'])}c", 
                               (row['Latency_mean'], row['TPS_mean']),
                               xytext=(8, 8), textcoords='offset points',
                               fontsize=9, fontweight='semibold', alpha=0.8,
                               bbox=dict(boxstyle='round,pad=0.3', facecolor='white', alpha=0.7))
            
            ax.set_title(f'{suite.replace("_", " ").title()}', fontweight='bold', fontsize=14, pad=20)
            ax.set_xlabel('Average Latency (ms)', fontweight='semibold')
            ax.set_ylabel('TPS (Transactions/sec)', fontweight='semibold')
            ax.legend(frameon=True, fancybox=True, shadow=True)
            ax.grid(True, alpha=0.3, linestyle='-', linewidth=0.5)
            ax.set_axisbelow(True)
        
        plt.tight_layout(rect=[0, 0.03, 1, 0.95])
        
        # Save with high quality
        scatter_file = self.output_dir / "throughput_vs_latency.png"
        plt.savefig(scatter_file, dpi=300, bbox_inches='tight', facecolor='white', edgecolor='none')
        print(f"   💾 Saved: {scatter_file}")
        
        return fig
    
    def create_summary_table(self, stats):
        """Generate summary table"""
        print("\n📋 Generating summary table...")
        
        # Create pivot table for better visualization
        pivot_tps = stats.pivot_table(
            index=['Suite', 'Clients'], 
            columns='Database_Type', 
            values='TPS_mean', 
            aggfunc='mean'
        ).round(1)
        
        pivot_latency = stats.pivot_table(
            index=['Suite', 'Clients'], 
            columns='Database_Type', 
            values='Latency_mean', 
            aggfunc='mean'
        ).round(2)
        
        # Calculate improvements/degradations
        if 'postgresql' in pivot_tps.columns and 'citus' in pivot_tps.columns:
            pivot_tps['Citus_vs_PG_%'] = ((pivot_tps['citus'] - pivot_tps['postgresql']) / pivot_tps['postgresql'] * 100).round(1)
            pivot_latency['Citus_vs_PG_%'] = ((pivot_latency['citus'] - pivot_latency['postgresql']) / pivot_latency['postgresql'] * 100).round(1)
        
        # Save tables
        summary_file = self.output_dir / "performance_summary.txt"
        with open(summary_file, 'w', encoding='utf-8') as f:
            f.write("═══════════════════════════════════════════════════════════════\n")
            f.write("            PERFORMANCE COMPARISON SUMMARY\n")
            f.write("                PostgreSQL vs Citus\n")
            f.write("═══════════════════════════════════════════════════════════════\n\n")
            f.write(f"Generated on: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n\n")
            
            f.write("📊 THROUGHPUT (TPS - Transactions Per Second)\n")
            f.write("─" * 60 + "\n")
            f.write(pivot_tps.to_string())
            f.write("\n\n")
            
            f.write("⏱️  LATENCY (ms - Milliseconds)\n")
            f.write("─" * 60 + "\n")
            f.write(pivot_latency.to_string())
            f.write("\n\n")
            
            # Summary analysis
            f.write("📈 SUMMARY ANALYSIS\n")
            f.write("─" * 60 + "\n")
            
            if 'postgresql' in pivot_tps.columns and 'citus' in pivot_tps.columns:
                avg_tps_pg = pivot_tps['postgresql'].mean()
                avg_tps_citus = pivot_tps['citus'].mean()
                avg_lat_pg = pivot_latency['postgresql'].mean()
                avg_lat_citus = pivot_latency['citus'].mean()
                
                f.write(f"Average PostgreSQL TPS: {avg_tps_pg:.1f}\n")
                f.write(f"Average Citus TPS: {avg_tps_citus:.1f}\n")
                f.write(f"TPS Difference: {((avg_tps_citus - avg_tps_pg) / avg_tps_pg * 100):.1f}%\n\n")
                
                f.write(f"Average PostgreSQL Latency: {avg_lat_pg:.2f} ms\n")
                f.write(f"Average Citus Latency: {avg_lat_citus:.2f} ms\n")
                f.write(f"Latency Difference: {((avg_lat_citus - avg_lat_pg) / avg_lat_pg * 100):.1f}%\n\n")
                
                if avg_tps_citus > avg_tps_pg:
                    f.write("🏆 Citus shows higher average throughput\n")
                else:
                    f.write("🏆 PostgreSQL shows higher average throughput\n")
                    
                if avg_lat_citus < avg_lat_pg:
                    f.write("⚡ Citus shows lower average latency\n")
                else:
                    f.write("⚡ PostgreSQL shows lower average latency\n")
        
        print(f"   💾 Table saved: {summary_file}")
        
        return pivot_tps, pivot_latency
    
    def generate_report(self):
        """Generate complete report"""
        print("🎯 Starting comparative report generation...")
        
        try:
            # 1. Load data
            data = self.load_data()
            
            # 2. Calculate statistics
            stats = self.calculate_statistics(data)
            
            # 3. Generate charts
            self.create_tps_comparison(stats)
            self.create_latency_comparison(stats)
            self.create_throughput_vs_latency(stats)
            
            # 4. Generate summary table
            self.create_summary_table(stats)
            
            # 5. Create HTML index
            self.create_html_index()
            
            print(f"\n✅ Report generated successfully!")
            print(f"📁 Files saved in: {self.output_dir}")
            print(f"🌐 Open index.html to view all charts")
            
        except Exception as e:
            print(f"\n❌ Error generating report: {e}")
            raise
    
    def create_html_index(self):
        """Create HTML page with all charts"""
        html_content = f"""
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Performance Benchmark: PostgreSQL vs Citus</title>
    <style>
        body {{
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            margin: 0;
            padding: 40px;
            background: linear-gradient(135deg, #f5f7fa 0%, #c3cfe2 100%);
            color: #333;
            line-height: 1.6;
        }}
        .container {{
            max-width: 1400px;
            margin: 0 auto;
            background: white;
            padding: 40px;
            border-radius: 15px;
            box-shadow: 0 10px 30px rgba(0,0,0,0.1);
        }}
        h1 {{
            color: #2c3e50;
            text-align: center;
            border-bottom: 4px solid #2E86AB;
            padding-bottom: 20px;
            margin-bottom: 30px;
            font-size: 2.5em;
        }}
        h2 {{
            color: #34495e;
            margin-top: 50px;
            font-size: 1.8em;
            border-left: 4px solid #F18F01;
            padding-left: 15px;
        }}
        .chart {{
            text-align: center;
            margin: 40px 0;
        }}
        .chart img {{
            max-width: 100%;
            height: auto;
            border: 2px solid #e8e8e8;
            border-radius: 12px;
            box-shadow: 0 5px 20px rgba(0,0,0,0.15);
            transition: transform 0.3s ease;
        }}
        .chart img:hover {{
            transform: scale(1.02);
        }}
        .info {{
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 25px;
            border-radius: 12px;
            margin: 30px 0;
            border-left: 5px solid #F18F01;
        }}
        .info strong {{
            color: #FFD700;
        }}
        .footer {{
            text-align: center;
            margin-top: 60px;
            padding: 25px;
            border-top: 2px solid #e8e8e8;
            color: #7f8c8d;
            background: #f8f9fa;
            border-radius: 8px;
        }}
        .download-btn {{
            display: inline-block;
            padding: 12px 25px;
            background: linear-gradient(135deg, #2E86AB 0%, #1565C0 100%);
            color: white;
            text-decoration: none;
            border-radius: 8px;
            margin: 8px;
            font-weight: 600;
            transition: all 0.3s ease;
            box-shadow: 0 3px 10px rgba(0,0,0,0.2);
        }}
        .download-btn:hover {{
            background: linear-gradient(135deg, #1565C0 0%, #0D47A1 100%);
            transform: translateY(-2px);
            box-shadow: 0 5px 15px rgba(0,0,0,0.3);
        }}
    </style>
</head>
<body>
    <div class="container">
        <h1>🏆 Performance Benchmark Analysis</h1>
        <h2 style="text-align: center; color: #2E86AB;">PostgreSQL vs Citus Comparative Study</h2>
        
        <div class="info">
            <p><strong>📅 Generated on:</strong> {datetime.now().strftime('%B %d, %Y at %H:%M:%S')}</p>
            <p><strong>📊 Data Source:</strong> pgbench benchmarks with TPC-B, Select-Only, and Simple-Update workloads</p>
            <p><strong>🎯 Objective:</strong> Compare performance between monolithic PostgreSQL and distributed Citus architectures</p>
            <p><strong>📚 Context:</strong> Graduate Thesis - Database Monitoring Guidelines</p>
        </div>
        
        <h2>📈 1. Throughput Comparison (TPS)</h2>
        <div class="chart">
            <img src="tps_comparison.png" alt="TPS Comparison Chart">
        </div>
        <p style="text-align: center; font-style: italic; color: #666;">
            This chart displays transactions per second (TPS) for each workload and client configuration, 
            showing the raw processing capacity of both database architectures.
        </p>
        
        <h2>⏱️ 2. Latency Analysis</h2>
        <div class="chart">
            <img src="latency_comparison.png" alt="Latency Comparison Chart">
        </div>
        <p style="text-align: center; font-style: italic; color: #666;">
            This chart shows average response time (latency) in milliseconds, 
            indicating the responsiveness of each system under different loads.
        </p>
        
        <h2>📊 3. Performance Trade-offs</h2>
        <div class="chart">
            <img src="throughput_vs_latency.png" alt="TPS vs Latency Scatter Plot">
        </div>
        <p style="text-align: center; font-style: italic; color: #666;">
            This scatter plot reveals the relationship between throughput and latency, 
            helping identify optimal performance configurations for each architecture.
        </p>
        
        <h2>📋 4. Download Resources</h2>
        <div style="text-align: center; padding: 20px;">
            <a href="performance_summary.txt" class="download-btn">📄 Detailed Summary</a>
            <a href="tps_comparison.png" class="download-btn" download>📊 TPS Chart (PNG)</a>
            <a href="latency_comparison.png" class="download-btn" download>⏱️ Latency Chart (PNG)</a>
            <a href="throughput_vs_latency.png" class="download-btn" download>📈 Scatter Plot (PNG)</a>
        </div>
        
        <div class="footer">
            <p><strong>Professional Benchmark Analysis Tool</strong></p>
            <p>Graduate Thesis Research - PostgreSQL vs Citus Performance Comparison</p>
            <p>Automated report generation for academic research purposes</p>
        </div>
    </div>
</body>
</html>
"""
        
        html_file = self.output_dir / "index.html"
        with open(html_file, 'w', encoding='utf-8') as f:
            f.write(html_content)
        
        print(f"   🌐 Professional HTML page created: {html_file}")


def main():
    parser = argparse.ArgumentParser(description='Professional PostgreSQL vs Citus Performance Comparison Generator')
    parser.add_argument('--base-dir', '-d', type=str, default=None,
                       help='Base project directory (default: current directory)')
    parser.add_argument('--output', '-o', type=str, default=None,
                       help='Output directory (default: ./comparison_charts)')
    
    args = parser.parse_args()
    
    try:
        # Create analyzer
        analyzer = BenchmarkAnalyzer(base_dir=args.base_dir)
        
        # Override output directory if specified
        if args.output:
            analyzer.output_dir = Path(args.output)
            analyzer.output_dir.mkdir(exist_ok=True)
        
        # Generate professional report
        analyzer.generate_report()
        
    except Exception as e:
        print(f"❌ Error: {e}")
        return 1
    
    return 0


if __name__ == "__main__":
    exit(main())