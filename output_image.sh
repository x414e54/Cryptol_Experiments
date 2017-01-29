rm -rf raytrace
mkdir raytrace
cd raytrace
echo "raytrace 256 256" > run_raytrace.scr

../.cabal-sandbox/bin/cryptol ../examples/funstuff/raytrace.cry -b run_raytrace.scr > temp

state="s"
cur_pixel=""

write_pixel() {
    local pixel="${cur_pixel/0x/\\x}"
    pixel="${pixel/1/FF}"
    pixel="${pixel/0/00}"
    echo -en "$pixel" >> raytrace.raw
    cur_pixel=""
}

while read -n1 char; do
    case "$state" in
        s)  if [ "$char" == "[" ]; then
                state="m" 
            fi
            ;;
        i)  case "$char" in
            ]) state="e"; 
               ;;
            [) state="r";
               ;;
            esac
            ;;
        r)  case "$char" in
            ,) write_pixel
               ;;
            ]) write_pixel
               state="i"
               ;;
            *) cur_pixel+=$char
               ;;
            esac
            ;;
    esac
done < temp

ffmpeg -vcodec rawvideo -f rawvideo -pix_fmt rgb888 -s 256x256 -i raytrace.raw -f image2 -vcodec png raytrace.png
