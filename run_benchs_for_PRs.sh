#!/bin/bash
# Exit on error
set -e

projectSrcFolder=fmt
repository='fmtlib/fmt'
#bearerToken=""
#backendServer=http://localhost:3000


benchsRootFolder="$(pwd)"
resultsFolder="$benchsRootFolder/results"
mkdir -p $resultsFolder

# With personal access token
# Set userAuth to `username:token`
if [ "$userAuth" != "" ]; then
    echo "using authent for API requests"
    userAuth="-u $userAuth"
fi


# Prepare system for benchmarking
sudo python3 -m pyperf system tune

cleanup()
{
    echo "================================================================="
    echo "=========== Reseting system to normal settings =================="
    echo "================================================================="
    sudo python3 -m pyperf system reset

    if [ "$notifyEmail" != "" ]; then
        echo "script ended" | mailx -s "pr replay script ended" $notifyEmail
    fi
}
trap cleanup EXIT

build_project()
{
    cmake -B build -GNinja -DCMAKE_BUILD_TYPE=Release -DFILE_BENCH=OFF || touch $1/.doesnotbuild
    cmake --build build --config Release || touch $1/.doesnotbuild
}

run_benchs()
{
    local resultsPrefix=$1
    local numIterations=$2
    echo "==== Running benchmark $numIterations times ===="
    for i in $(seq 1 $numIterations)
    do
        pushd build
        for benchname in "concat-benchmark" "find-pow10-benchmark" "vararg-benchmark" "int-benchmark" "parse-benchmark"; do
            BENCHMARK_BENCHMARK_OUT="$resultsPrefix/$benchname$i.json"
            echo "output is $BENCHMARK_BENCHMARK_OUT"
            ./$benchname --benchmark_out=$BENCHMARK_BENCHMARK_OUT
        done
        popd
    done
}

build_and_bench()
{
    local resultsPrefix="$resultsFolder/$1"
    local numIterations=$2

    if [ ! -d $resultsPrefix ] || [ -e $resultsPrefix/.dirty ]; then
        mkdir $resultsPrefix -p
        touch $resultsPrefix/.dirty

        build_project $resultsPrefix
        
        if [ ! -e $resultsPrefix/.doesnotbuild ]; then
            run_benchs $resultsPrefix $numIterations
        else
            echo "$1 does not build." > build_errors.txt
        fi

        rm $resultsPrefix/.dirty
    else
        echo "Skipping $1, was already done."
    fi
}

checkout_commit()
{
    # Checkout, then on failure try to fetch the commit and try again
    # This happens if the local repository does not have the latest versions of PR or if the PR was closed
    git checkout $1 || (git fetch --depth=1 origin $1 && git checkout $1)
}

checkout_build_and_bench()
{
    pushd $projectSrcFolder
    checkout_commit $1
    popd
    build_and_bench $1 $2
}

checkout_build_and_benchPR()
{
    local prNumber=$1
    local targetCommit=$2
    local targetRef=$3
    local mergeCommit=$4
    local iterations=$5
    checkout_build_and_bench $targetCommit $iterations
    checkout_build_and_bench $mergeCommit $iterations
}

submit_commit_to_calcite()
{
    local commitSHA=$1
    local ref=$2
    local prNumber=$3
    local resultsPrefix="$resultsFolder/$1"

    pushd $benchsRootFolder/$projectSrcFolder
    checkout_commit $commitSHA

    if [ ! -d $resultsPrefix ] || [ -e $resultsPrefix/.dirty ]; then
        echo "skipping commit $commitSHA, either dirty or no data."
    elif [ -e $resultsPrefix/.doesnotbuild ]; then
        echo "skipping commit $commitSHA, was not compiling."
    elif [ -e $resultsPrefix/.uploaded ]; then
        echo "Commit $commitSHA bench was already uploaded to calcite, skipping."
    else
        echo "uploading $commitSHA ($ref) bench to calcite."

        # Assume CALCITE_TOKEN and CALCITE_URL is set
        uploadCommand="npx calcite upload $benchsRootFolder/.calcite/config.js -R $ref"
        if [ "$prNumber" != "" ]; then
            echo "PR id is: $prNumber"
            uploadCommand="$uploadCommand -PR $prNumber"
        fi

        local reportFiles=""
        for report in $resultsPrefix/*.json; do
            if [ -z $reportFiles ]; then
                reportFiles=$report
            else
                reportFiles="$reportFiles:$report"
            fi
        done
        echo "reportFiles=$reportFiles"


        BENCHMARK_BENCHMARK_OUT="$reportFiles" $uploadCommand && touch $resultsPrefix/.uploaded
    fi

    popd
}

submit_pr_to_calcite()
{
    local prNumber=$1
    local targetCommit=$2
    local targetRef=$3
    local mergeCommit=$4
    local iterations=$5
    echo "Submitting PR $prNumber commits to calcite"
    submit_commit_to_calcite $targetCommit $targetRef
    submit_commit_to_calcite $mergeCommit "refs/pull/$prNumber/merge" $prNumber
}

list_pr_regressions()
{
    local prNumber=$1
    local targetCommit=$2
    local targetRef=$3
    local mergeCommit=$4
    local iterations=$5

    if [ "$bearerToken" == "" ]; then
        echo "please set the 'bearerToken' env variable to the calcite bearer token"
        false
    fi

    if [ "$backendServer" == "" ]; then
        echo "please set the 'backendServer' variable"
        false
    fi

    nbRegressedDatapoints=$(curl -s -L -H "Authorization: Bearer $bearerToken" $backendServer/api/projects/$CALCITE_TOKEN/baseline/commit-id/$targetCommit/targets/commit-id/$mergeCommit | jq '.abstract.regressedDatapointsCount')
    if [ "$nbRegressedDatapoints" == "" ]; then
        false
    fi
    #if [ "$nbRegressedDatapoints" != "0" ] && [ "$nbRegressedDatapoints" != "null" ]; then
        echo "PR $1 has $nbRegressedDatapoints regressed datapoints (base=$targetCommit merge=$mergeCommit)"
    #fi
}

for_each_pr()
{
    pushd $projectSrcFolder

    local prNumber=$2
    local iterations=$3

    echo "Fetching information from API"
    local prInfo=$(curl $userAuth -s -L "https://api.github.com/repos/$repository/pulls/$prNumber")
    local prStatus=$(jq '.state' <<< $prInfo)

    if [ $prStatus == "null" ]; then
        echo "================================================================="
        echo "Could not get information about PR $prNumber. Skipping it."
        echo "================================================================="
        touch $resultsFolder/.mr$prNumber-notfound
    else
        rm "$resultsFolder/.mr$prNumber-notfound" 2> /dev/null || true
        local prStatus=$(jq '.state' <<< $prInfo)
        local targetCommit=$(jq -r '.base.sha' <<< $prInfo)
        local targetRef="refs/heads/$(jq -r '.base.ref' <<< $prInfo)"
        local mergeCommit=$(jq -r '.merge_commit_sha' <<< $prInfo)
        if [ $mergeCommit == "null" ]; then
            echo "================================================================="
            echo "Could not get merge commit for PR $prNumber. Skipping it."
            echo "It is possible it was closed or not mergeable."
            echo "================================================================="
            touch $resultsFolder/.mr$prNumber-notfound
        else
            echo "================================================================="
            echo " Benchmarking PR $prNumber"
            echo " prStatus=$prStatus"
            echo " targetCommit=$targetCommit"
            echo " targetRef=$targetRef"
            echo " mergeCommit=$mergeCommit"
            echo "================================================================="
        fi
    fi

    popd

    if [ ! -e $resultsFolder/.mr$prNumber-notfound ]; then
        $1 $prNumber $targetCommit $targetRef $mergeCommit $iterations
    fi

}


iterations=5

./bootstrap.sh


get_pr_number_list()
{
    prNumbersList=""
    for page in $(seq 1 20) ; do
        echo "downloading page $page"
        results=$(curl $userAuth -s -L "https://api.github.com/repos/$repository/pulls?state=all&page=$page")
        echo "parsing page $page"
        prNumbersList="$prNumbersList $(jq -r '.[].number' <<< $results)" || echo "results\n $results"
    done
    echo $prNumbersList
}

prNumbersList="1800 1792 1790 1786 1783 1781 1777 1775 1773 1770 1767 1763 1761 1760 1757 1751 1750 1749 1744 1741 1740 1739 1738 1737 1734 1729 1728 1721 1717 1716 1714 1706 1705 1703 1702 1699 1698 1697 1696 1693 1691 1689 1687 1683 1681 1678 1677 1670 1669 1667 1663 1661 1660 1657 1656 1650 1643 1641 1635 1633 1629 1627 1616 1606 1603 1602 1598 1596 1591 1590 1589 1584 1582 1581 1580 1578 1577 1576 1575 1574 1573 1572 1571 1570 1569 1568 1561 1560 1554 1553 1546 1535 1534 1533 1532 1530 1528 1523 1522 1521 1520 1519 1518 1516 1513 1512 1505 1492 1489 1485 1483 1481 1480 1479 1477 1475 1470 1469 1468 1466 1464 1454 1451 1446 1443 1440 1439 1438 1437 1435 1434 1433 1432 1428 1427 1425 1418 1416 1414 1410 1407 1406 1404 1400 1397 1394 1390 1387 1386 1384 1383 1382 1371 1370 1364 1361 1360 1358 1357 1356 1355 1351 1349 1347 1345 1343 1342 1341 1337 1334 1332 1331 1330 1328 1326 1325 1320 1317 1315 1312 1301 1294 1293 1290 1287 1286 1285 1280 1279 1278 1276 1265 1263 1254 1252 1250 1243 1238 1236 1235 1231 1230 1217 1206 1199 1191 1190 1187 1182 1177 1171 1167 1163 1159 1157 1155 1151 1150 1147 1144 1139 1135 1134 1133 1121 1114 1113 1110 1107 1103 1102 1099 1094 1093 1092 1091 1089 1087 1086 1083 1079 1078 1075 1074 1071 1069 1068 1067 1061 1060 1058 1054 1052 1051 1040 1039 1031 1030 1029 1028 1027 1022 1021 1019 1012 1006 1001 999 998 995 994 989 988 983 982 981 979 974 973 971 967 962 961 959 957 956 954 953 950 949 946 943 937 934 933 926 924 921 919 916 913 909 907 906 902 901 899 898 897 896 895 894 891 890 889 887 886 885 883 882 881 875 872 870 868 867 863 854 852 845 844 839 838 827 819 815 811 810 806 805 804 803 800 797 792 790 780 775 774 773 772 771 767 766 763 759 739 738 736 735 733 732 730 726 725 724 723 720 719 717 716 712 709 708 706 705 696 694 693 681 680 679 676 661 660 658 656 655 653 649 641 640 635 633 631 626 622 620 617 616 610 609 607 606 605 604 603 602 598 595 592 591 588 587 586 585 583 582 578 574 571 569 568 567 563 559 556 553 550 549 547 545 542 540 539 536 534 527 526 520 515 513 511 510 503 502 499 497 495 494 493 490 485 482 481 475 473 469 466 458 457 456 453 450 448 446 445 444 441 420 419 410 409 407 405 403 402 399 397 396 393 390 389 387 386 385 384 382 381 366 364 362 361 358 348 340 339 333 328 313 312 309 299 286 285 277 273 271 267 264 262 259 258 256 251 249 245 243 241 240 239 236 230 229 228 221 220 218 215 214 212 208 207 206 204 200 199 198 197 196 191 189 174 173 169 168 161 160 154 153 149 141 138 137 136 134 130 121 119 118 116 114 113 112 111 110 108 107 104 102 101 98 97 91 89 87 81 79 78 77 56 47 46 44 28 27 26 20 18 13 8 7 6 4"

action=checkout_build_and_benchPR
#action=submit_pr_to_calcite
#action=list_pr_regressions

for pr in $prNumbersList; do
    echo "Executing script for PR $pr"
    for_each_pr $action $pr $iterations
done

