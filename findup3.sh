#!/bin/bash

#Leave empty if not verbose
VERBOSE=
#Don't change
SECONDENTRYSUFFIX=__without_tags__
#Where to store the data files. A subdir /detailed/ and /duplicates/ must exist
OUTDIR=/dir/to/store/output/in/
#Counters
NUMFILES=0
NUMHASHES=0
DATESTART=$(date '+%s')

#Change these for your situation
cd /dir/to/start/find/in/
FILES="* .[^.]*"

#Move old .hashes.txt out of the way and open it for reading on file descriptor 8
mv $OUTDIR/duplicates/.hashes.txt $OUTDIR/duplicates/.hashes.old.txt
exec 8<$OUTDIR/duplicates/.hashes.old.txt
#Open new .hashes.txt on file descriptor 9
exec 9>$OUTDIR/duplicates/.hashes.txt
#Open a temp file for the MP3's
TMP=$(mktemp)


#Go through the records. The input to this loop is given at the end of the loop, in a subshell.
while read -r nDI nM nS nN
 do
  [[ $VERBOSE ]] && printf "Processing file %s..." "$nN"
  #advance the record from fd8
  while [[ $oDI < $nDI ]] && read -r -u8 NEWoDI NEWoM NEWoS NEWoH NEWoN
   do
    oDI=$NEWoDI
    oM=$NEWoM
    oS=$NEWoS
    oH=$NEWoH
    oN=$NEWoN
    [[ $VERBOSE ]] && printf 'Advancing to %s...' "$oN"
  done
  #Check if old hash is valid
  if [[ $nDI\ $nM\ $nS == $oDI\ $oM\ $oS ]]
   then
    [[ $VERBOSE ]] && echo "Skipping, equal to $oN."
    #print OLD hash with the NEW name to fd9
    printf '%s\t%s\t%12s\t%s\t%s\n' "$nDI" "$nM" "$nS" "$oH" "$nN" >&9
    ((NUMFILES++))
    #there may be a "second entry" (specifically, if the file is .mp3), so advance the old file by one line and check for it
    if read -r -u8 NEWoDI NEWoM NEWoS NEWoH NEWoN
     then
      oDI=$NEWoDI
      oM=$NEWoM
      oS=$NEWoS
      oH=$NEWoH
      oN=$NEWoN
      [[ $VERBOSE ]] && printf 'Advancing to %s...' "$oN"
      #Check if this line has the same (DI)(M) as the previous. Not (S), since that is recomputed
      if [[ $nDI\ $nM == $oDI\ $oM ]]
       then
        [[ $VERBOSE ]] && echo "Valid second entry found!"
        #print OLD hash with the NEW UPDATED name and OLD size to fd9
        printf '%s\t%s\t%12s\t%s\t%s%s\n' "$nDI" "$nM" "$oS" "$oH" "$nN" "$SECONDENTRYSUFFIX" >&9
        ((NUMFILES++))
       else
        [[ $VERBOSE ]] && echo " ."
      fi
    fi
   else
    [[ $VERBOSE ]] && echo "Computing."
    #Compute hash of file
    #  Since the file is quoted and escaped, unquote it and run it through printf to get the "real" filename, then via xargs to cat and sha1sum
    #  The benefit of piping through cat is that there is a fallback: if the file can't be read it will get a default checksum=sha1sum("")
    nH=$(printf "${nN:1:$((${#nN}-2))}" | xargs -0 cat | sha1sum | head -c40)
    #print new entry to fd9
    printf '%s\t%s\t%12s\t%s\t%s\n' "$nDI" "$nM" "$nS" "$nH" "$nN" >&9
    ((NUMHASHES++))
    ((NUMFILES++))
    #Check if file is MP3
    if [[ $nN =~ \.[Mm][Pp]3\'$ ]]
     then
      [[ $VERBOSE ]] && printf " --> Found MP3 file..."
      #make a temp copy of the file
      printf "${nN:1:$((${#nN}-2))}" | xargs -0rI '////' cp "////" $TMP
      #Strip tags, suppressing output if not verbose
      [[ $VERBOSE ]] && id3v2 -D $TMP || id3v2 -D $TMP >/dev/null
      #get the new checksum
      mH=$(sha1sum $TMP | head -c40)
      #get the new size
      mS=$(stat --printf='%s' $TMP)
      #check if checksum and size of the stripped MP3 are different from the original file.
      #  if not, the stripping had no effect, probably because the MP3 does not have any tags.
      if [[ $mH\ $mS != $nH\ $nS ]]
       then
        #If stripped MP3 is different from the original: print new entry to fd9
        printf '%s\t%s\t%12s\t%s\t%s%s\n' "$nDI" "$nM" "$mS" "$mH" "$nN" "$SECONDENTRYSUFFIX" >&9
        ((NUMHASHES++))
        ((NUMFILES++))
       else
        [[ $VERBOSE ]] && echo " --> Skipping, found no tags to strip."
      fi
    fi
  fi
#Use BASH-only syntax to now call the INPUT to the while-read loop as a subshell
done < <(
  #Execute find, print out the "detailed report", then select regular files
  find -H $FILES -fls $OUTDIR/detailed/find-ls.root.txt -type f -print0 |

  #Call stat on the files, fetching the following data:
  #  Device number and inode number (DI)
  #  Modification time, as seconds since epoch (M)
  #  Size in bytes (S)
  #  Filename, quoted and escaped (N)
  xargs -0 stat --printf='%010d.%010i\t%012Y\t%s\t%N\n' |

  #Sort the output, effectively by (DI)
  sort
  
  #End the subshell
)


#Cleanup: close fd9 and remove the tempfile
9>&-
rm $TMP


#Phase 2: sort the final .hashes.txt by size and hash and print out duplicates

#Throw away (DI)(M), keep (S)(H)(N)
cut -c36- $OUTDIR/duplicates/.hashes.txt | 
#Sort the files, biggest first
sort -rn |
#Duplicates are found when two lines are equal in the first 53 characters (12 for (S), 40 for (H) and one tab)
uniq -w54 --all-repeated=separate > $OUTDIR/duplicates/duplicates.txt


#Phase 3: write out statistics
DATESTOP=$(date '+%s')
DATENOW=$(date)

printf '%s ::%11d files processed,%11d hashes calculated,%6d seconds\n' \
  "$DATENOW" $NUMFILES $NUMHASHES $(($DATESTOP-$DATESTART)) >> $OUTDIR/duplicates/.statistics.txt
