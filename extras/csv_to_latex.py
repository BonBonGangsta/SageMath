import csv

def csv_to_latex_table(input_csv, output_txt):
    with open(input_csv, newline='') as csvfile:
        reader = csv.reader(csvfile)
        rows = list(reader)

    num_columns = len(rows[0]) if rows else 0
    latex = []

    # LaTeX table header
    latex.append(r"\begin{tabular}{" + " ".join(["c"] * num_columns) + r"}")
    latex.append(r"\hline")

    for row in rows:
        line = " & ".join(row) + r" \\"
        latex.append(line)
        #latex.append(r"\hline")

    latex.append(r"\end{tabular}")

    # Write to .txt file
    with open(output_txt, "w") as f:
        f.write("\n".join(latex))

    print(f"LaTeX table written to: {output_txt}")

# Example usage:
csv_to_latex_table("data.csv", "table_output.txt")