set datafile separator ","
set key autotitle columnhead
set xlabel "x (m)"
set ylabel "y (m)"
set size ratio -1
plot "scripts/example1.csv" using 2:3 with lines title "Example 1 (manually placing segments)", \
      "scripts/example1_points.csv" using 1:2:3 with labels point pt 7 ps 1.5 lc rgb "red" notitle, \
      "scripts/example2.csv" using 2:3 with lines title "Example 2 (PI: one corner)", \
      "scripts/example2_points.csv" using 1:2:3 with labels point pt 7 ps 1.5 lc rgb "red" notitle, \
      "scripts/example3.csv" using 2:3 with lines title "Example 3 (PI: several corners)", \
      "scripts/example3_points.csv" using 1:2:3 with labels point pt 7 ps 1.5 lc rgb "red" notitle
