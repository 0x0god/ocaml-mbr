(*
 * Copyright (C) 2013 Citrix Inc
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

let ( >>= ) = Result.bind
let sizeof_part = 16

module Geometry = struct
  type t = { cylinders : int; heads : int; sectors : int }

  let kib = 1024L
  let mib = Int64.mul kib 1024L

  let unmarshal buf : (t, _) result =
    (if Cstruct.length buf < 3 then
     Error (Printf.sprintf "geometry too small: %d < %d" (Cstruct.length buf) 3)
    else Ok ())
    >>= fun () ->
    let heads = Cstruct.get_uint8 buf 0 in
    let y = Cstruct.get_uint8 buf 1 in
    let z = Cstruct.get_uint8 buf 2 in
    let sectors = y land 0b0111111 in
    let cylinders = (y lsl 2) lor z in
    Ok { cylinders; heads; sectors }

  let of_lba_size x =
    let sectors = 63 in
    (if x < Int64.(mul 504L mib) then Ok 16
    else if x < Int64.(mul 1008L mib) then Ok 64
    else if x < Int64.(mul 4032L mib) then Ok 128
    else if x < Int64.(add (mul 8032L mib) (mul 512L kib)) then Ok 255
    else Error (Printf.sprintf "sector count exceeds LBA max: %Ld" x))
    >>= fun heads ->
    let cylinders =
      Int64.(to_int (div (div x (of_int sectors)) (of_int heads)))
    in
    Ok { cylinders; heads; sectors }

  let to_chs g x =
    let open Int64 in
    let cylinders = to_int (div x (mul (of_int g.sectors) (of_int g.heads))) in
    let heads = to_int (rem (div x (of_int g.sectors)) (of_int g.heads)) in
    let sectors = to_int (succ (rem x (of_int g.sectors))) in
    { cylinders; heads; sectors }
end

module Partition = struct
  type t = {
    active : bool;
    first_absolute_sector_chs : Geometry.t;
    ty : int;
    last_absolute_sector_chs : Geometry.t;
    first_absolute_sector_lba : int32;
    sectors : int32;
  }

  let sector_start t =
    Int64.(logand (of_int32 t.first_absolute_sector_lba) 0xFFFF_FFFFL)

  let size_sectors t = Int64.(logand (of_int32 t.sectors) 0xFFFF_FFFFL)

  let make ?(active = false) ?(ty = 6) first_absolute_sector_lba sectors =
    (* ty has to fit in a uint8_t, and ty=0 is reserved for empty partition entries *)
    (if ty > 0 && ty < 256 then Ok ()
    else Error "Mbr.Partition.make: ty must be between 1 and 255")
    >>= fun () ->
    let first_absolute_sector_chs =
      { Geometry.cylinders = 0; heads = 0; sectors = 0 }
    in
    let last_absolute_sector_chs = first_absolute_sector_chs in
    Ok
      {
        active;
        first_absolute_sector_chs;
        ty;
        last_absolute_sector_chs;
        first_absolute_sector_lba;
        sectors;
      }

  let make' ?active ?ty sector_start size_sectors =
    if
      Int64.(
        logand sector_start 0xFFFF_FFFFL = sector_start
        && logand size_sectors 0xFFFF_FFFFL = size_sectors)
    then
      make ?active ?ty
        (Int64.to_int32 sector_start)
        (Int64.to_int32 size_sectors)
    else Error "partition parameters do not fit in int32"

  let _ = assert (sizeof_part = 16)
  let sizeof = sizeof_part

  let unmarshal buf =
    (if Cstruct.length buf < sizeof_part then
     Error
       (Printf.sprintf "partition entry too small: %d < %d" (Cstruct.length buf)
          sizeof_part)
    else Ok ())
    >>= fun () ->
    let buf = Cstruct.sub buf 0 sizeof_part in
    let get_part_ty v = Cstruct.get_uint8 v 4 in
    let ty = get_part_ty buf in
    if ty == 0x00 then
      if Cstruct.for_all (( = ) '\000') buf then Ok None
      else Error "Non-zero empty partition type"
    else
      let get_part_status v = Cstruct.get_uint8 v 0 in
      let active = get_part_status buf = 0x80 in
      let get_part_first_absolute_sector_chs src = Cstruct.sub src 1 3 in
      Geometry.unmarshal (get_part_first_absolute_sector_chs buf)
      >>= fun first_absolute_sector_chs ->
      let get_part_last_absolute_sector_chs src = Cstruct.sub src 5 3 in
      Geometry.unmarshal (get_part_last_absolute_sector_chs buf)
      >>= fun last_absolute_sector_chs ->
      let get_part_first_absolute_sector_lba v = Cstruct.LE.get_uint32 v 8 in
      let first_absolute_sector_lba = get_part_first_absolute_sector_lba buf in
      let get_part_sectors v = Cstruct.LE.get_uint32 v 12 in
      let sectors = get_part_sectors buf in
      Ok
        (Some
           {
             active;
             first_absolute_sector_chs;
             ty;
             last_absolute_sector_chs;
             first_absolute_sector_lba;
             sectors;
           })

  let marshal (buf : Cstruct.t) t =
    let set_part_status v x = Cstruct.set_uint8 v 0 x in
    set_part_status buf (if t.active then 0x80 else 0);
    let set_part_ty v x = Cstruct.set_uint8 v 4 x in
    set_part_ty buf t.ty;
    let set_part_first_absolute_sector_lba v x = Cstruct.LE.set_uint32 v 8 x in
    set_part_first_absolute_sector_lba buf t.first_absolute_sector_lba;
    let set_part_sectors v x = Cstruct.LE.set_uint32 v 12 x in
    set_part_sectors buf t.sectors
end

type t = {
  bootstrap_code : string;
  original_physical_drive : int;
  seconds : int;
  minutes : int;
  hours : int;
  disk_signature : int32;
  partitions : Partition.t list;
}

let make partitions =
  (if List.length partitions <= 4 then Ok () else Error "Too many partitions")
  >>= fun () ->
  let num_active =
    List.fold_left
      (fun acc p -> if p.Partition.active then succ acc else acc)
      0 partitions
  in
  (if num_active <= 1 then Ok ()
  else Error "More than one active/boot partitions is not advisable")
  >>= fun () ->
  let partitions =
    List.sort
      (fun p1 p2 ->
        Int32.unsigned_compare p1.Partition.first_absolute_sector_lba
          p2.Partition.first_absolute_sector_lba)
      partitions
  in
  (* Check for overlapping partitions *)
  List.fold_left
    (fun r p ->
      r >>= fun offset ->
      if
        Int32.unsigned_compare offset p.Partition.first_absolute_sector_lba <= 0
      then
        Ok (Int32.add p.Partition.first_absolute_sector_lba p.Partition.sectors)
      else Error "Partitions overlap")
    (Ok 1l) (* We start at 1 so the partitions don't overlap with the MBR *)
    partitions
  >>= fun (_ : int32) ->
  let bootstrap_code = String.init (218 + 216) (Fun.const '\000') in
  let original_physical_drive = 0 in
  let seconds = 0 in
  let minutes = 0 in
  let hours = 0 in
  let disk_signature = 0l in
  Ok
    {
      bootstrap_code;
      original_physical_drive;
      seconds;
      minutes;
      hours;
      disk_signature;
      partitions;
    }

(* "modern standard" MBR from wikipedia: *)

let sizeof_mbr = 512
let _ = assert (sizeof_mbr = 512)

let unmarshal (buf : Cstruct.t) : (t, string) result =
  (if Cstruct.length buf < sizeof_mbr then
   Error
     (Printf.sprintf "MBR too small: %d < %d" (Cstruct.length buf) sizeof_mbr)
  else Ok ())
  >>= fun () ->
  let get_mbr_signature1 v = Cstruct.get_uint8 v 510 in
  let signature1 = get_mbr_signature1 buf in
  let get_mbr_signature2 v = Cstruct.get_uint8 v 511 in
  let signature2 = get_mbr_signature2 buf in
  (if signature1 = 0x55 && signature2 = 0xaa then Ok ()
  else
    Error
      (Printf.sprintf "Invalid signature: %02x %02x <> 0x55 0xaa" signature1
         signature2))
  >>= fun () ->
  let get_mbr_bootstrap_code1 src = Cstruct.sub src 0 218 in
  let bootstrap_code =
    let get_mbr_bootstrap_code2 src = Cstruct.sub src 224 216 in
    Cstruct.append (get_mbr_bootstrap_code1 buf) (get_mbr_bootstrap_code2 buf)
  in
  let bootstrap_code = Cstruct.to_string bootstrap_code in
  let get_mbr_original_physical_drive v = Cstruct.get_uint8 v 220 in
  let original_physical_drive = get_mbr_original_physical_drive buf in
  let get_mbr_seconds v = Cstruct.get_uint8 v 221 in
  let seconds = get_mbr_seconds buf in
  let get_mbr_minutes v = Cstruct.get_uint8 v 222 in
  let minutes = get_mbr_minutes buf in
  let get_mbr_hours v = Cstruct.get_uint8 v 223 in
  let hours = get_mbr_hours buf in
  let get_mbr_disk_signature v = Cstruct.LE.get_uint32 v 440 in
  let disk_signature = get_mbr_disk_signature buf in
  let get_mbr_partitions src = Cstruct.sub src 446 64 in
  let partitions = get_mbr_partitions buf in
  Partition.unmarshal (Cstruct.shift partitions (0 * Partition.sizeof))
  >>= fun p1 ->
  Partition.unmarshal (Cstruct.shift partitions (1 * Partition.sizeof))
  >>= fun p2 ->
  Partition.unmarshal (Cstruct.shift partitions (2 * Partition.sizeof))
  >>= fun p3 ->
  Partition.unmarshal (Cstruct.shift partitions (3 * Partition.sizeof))
  >>= fun p4 ->
  let partitions = List.filter_map Fun.id [ p1; p2; p3; p4 ] in
  Ok
    {
      bootstrap_code;
      original_physical_drive;
      seconds;
      minutes;
      hours;
      disk_signature;
      partitions;
    }

let marshal (buf : Cstruct.t) t =
  let bootstrap_code1 = String.sub t.bootstrap_code 0 218
  and bootstrap_code2 = String.sub t.bootstrap_code 218 216 in
  let set_mbr_bootstrap_code1 src srcoff dst =
    Cstruct.blit_from_string src srcoff dst 0 218
  in
  set_mbr_bootstrap_code1 bootstrap_code1 0 buf;
  let set_mbr_bootstrap_code2 src srcoff dst =
    Cstruct.blit_from_string src srcoff dst 224 216
  in
  set_mbr_bootstrap_code2 bootstrap_code2 0 buf;
  let set_mbr_original_physical_drive v x = Cstruct.set_uint8 v 220 x in
  set_mbr_original_physical_drive buf t.original_physical_drive;
  let set_mbr_seconds v x = Cstruct.set_uint8 v 221 x in
  set_mbr_seconds buf t.seconds;
  let set_mbr_minutes v x = Cstruct.set_uint8 v 222 x in
  set_mbr_minutes buf t.minutes;
  let set_mbr_hours v x = Cstruct.set_uint8 v 223 x in
  set_mbr_hours buf t.hours;
  let set_mbr_disk_signature v x = Cstruct.LE.set_uint32 v 440 x in
  set_mbr_disk_signature buf t.disk_signature;
  let get_mbr_partitions src = Cstruct.sub src 446 64 in
  let partitions = get_mbr_partitions buf in
  let _ =
    List.fold_left
      (fun buf p ->
        Partition.marshal buf p;
        Cstruct.shift buf Partition.sizeof)
      partitions t.partitions
  in
  let set_mbr_signature1 v x = Cstruct.set_uint8 v 510 x in
  set_mbr_signature1 buf 0x55;
  let set_mbr_signature2 v x = Cstruct.set_uint8 v 511 x in
  set_mbr_signature2 buf 0xaa

let sizeof = sizeof_mbr
let default_partition_start = 2048l
