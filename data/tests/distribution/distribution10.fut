-- Once failed in kernel extraction.  The problem was that the map and
-- reduce are fused together into a redomap with a map-out array.
-- This was not handled correctly when it was turned into a
-- group-level stream.
--
-- ==
-- structure distributed { If/True/Kernel 1 If/False/Kernel 4 }

fun indexOfMax8 ((x,i): (u8,int)) ((y,j): (u8,int)): (u8,int) =
  if x < y then (y,j) else (x,i)

fun max8 (max_v: u8) (v: u8): u8 =
  if max_v < v then v else max_v

fun main(frame : [h][w]int) : [h][w]u8 =
  map (fn row: [w]u8 =>
         let rs = map u8 row
         let m = reduce max8 0u8 rs
         let rs' = map (max8 m) rs
         in rs')
   frame
