rm -rf circle
mkdir circle
cd circle
echo "movie 1" > run_circle.scr

../.cabal-sandbox/bin/cryptol ../examples/funstuff/circle.cry -b run_circle.scr > temp

state="s"
frame=0
cur_pixel=""

write_pixel() {
    local pixel="${cur_pixel/0x/\\x}"
    pixel="${pixel/1/FF}"
    pixel="${pixel/0/00}"
    echo -en "$pixel" >> m$frame.raw
    cur_pixel=""
}

while read -n1 char; do
    case "$state" in
        s)  if [ "$char" == "[" ]; then
                state="m" 
            fi
            ;;
        m)  case "$char" in
            ]) state="e"; 
               ;;
            [) state="f";
               ;;
            esac
            ;;
        f)  case "$char" in
            [) state="r";
               ;;
            ]) state="m";
               ((frame++))
               ;;
            esac
            ;;
        r)  case "$char" in
            ,) write_pixel
               ;;
            ]) write_pixel
               state="f"
               ;;
            *) cur_pixel+=$char
               ;;
            esac
            ;;
    esac
done < temp

ffmpeg -f image2 -framerate 1 -s 8x8 -pix_fmt gray -vcodec rawvideo -i m%1d.raw circle.avi

