/* Function for dynamically populating QA report with plots, images, and
 * summary data.
 * Makes some assumptions about the document (see index-js.html).
 * Most of this code comes from Chris Petty (thanks!).
 */

$(document).ready(function(){
    /* test for IE version to set certain behavior accordingly */
    var useSimple = false;
    var isIE = false;
    if (/MSIE (\d+\.\d+);/.test(navigator.userAgent)){ //test for MSIE x.x;
        isIE = true;
        var ieversion=new Number(RegExp.$1) // capture x.x portion and store as a number
	if (ieversion < 9) {
	    useSimple = true;
	}
    }

    var urlParams = {};
    (function () {
	var e,
        a = /\+/g,  // Regex for replacing addition symbol with a space
        r = /([^&=]+)=?([^&]*)/g,
        d = function (s) { return decodeURIComponent(s.replace(a, " ")); },
        q = window.location.search.substring(1);

	while (e = r.exec(q))
	    urlParams[d(e[1])] = d(e[2]);
    })();

    /* grab optional base data path from URL */
    var url = document.URL;
    var datapath = urlParams['datapath'] ? (urlParams['datapath'] + "/") : "";
    //alert(datapath);


    /* list of all qa items, descriptions, plus the following values:
     * de-mean (true/false), scale by mean (true/false), if scaling then mean is volmean (true/false), if scaling then mean is masked volmean (true/false), plot percentage of mean (true/false), default y-axis min (can be null), default y-axis max (can be null), histogram using z-scores instead of plotted values (true/false) */
    var qalist = [ 
	{
	    name:              "volmean",
	    plottitle:         "Volume means",
	    description:       "This metric tracks the mean intensity of each volume (time point) in the data.  Increases and decreases in overall  brain activity will be reflected in this plot.  RF spikes and other acquisition artifacts may be visible here (esp. if they affect an entire volume).",
	    demean:            true,
	    meanscale:         true,
	    meanvolmean:       true,
	    meanmaskedvolmean: false,
	    plotpercent:       true,
	    ymin:              -3,
	    ymax:              3,
	    yaxistitle:        "Mean intensity (% from baseline)",
	    histozscore:       true,
	    historange:        [-5, 5]
	},
	{
	    name:              "masked_volmean",
	    plottitle:         "Masked, detrended volume means",
	    description:       "This is the <b><i>volume means</i></b> metric applied to masked and detrended data.</p> <p><b>Volume means:</b> this metric tracks the mean intensity of each volume (time point) in the data.  Increases and decreases in overall brain activity will be reflected in this plot.  RF spikes and other acquisition artifacts may be visible here (esp. if they affect an entire volume).",
	    demean:            true,
	    meanscale:         true,
	    meanvolmean:       false,
	    meanmaskedvolmean: true,
	    plotpercent:       true,
	    ymin:              -3,
	    ymax:              3,
	    yaxistitle:        "Mean intensity (% from baseline)",
	    histozscore:       true,
	    historange:        [-5, 5]
	},
	{
	    name:              "mean_difference",
	    plottitle:         "Means of mean volume difference",
	    description:       "For each volume <i>vol</i> and a mean volume <i>meanvol</i>, this metric tracks the mean intensity of (<i>vol</i> - <i>meanvol</i>).  Slow drifts in the input data will be apparent in this plot.",
	    demean:            true,
	    meanscale:         true,
	    meanvolmean:       true,
	    meanmaskedvolmean: false,
	    plotpercent:       true,
	    ymin:              -3,
	    ymax:              3,
	    yaxistitle:        "Mean of mean volume difference (% from baseline)",
	    histozscore:       true,
	    historange:        [-5, 5]
	},
	{
	    name:              "masked_tdiff_volmean",
	    plottitle:         "Masked, detrended running difference ('velocity')",
	    description:       "This metric tracks the change in the mean intensity of consecutive volumes by subtracting the mean intensity of each volume from the mean intensity of its subsequent volume.",
	    demean:            true,
	    meanscale:         true,
	    meanvolmean:       false,
	    meanmaskedvolmean: true,
	    plotpercent:       true,
	    ymin:              -3,
	    ymax:              3,
	    yaxistitle:        "Mean of running difference volume (% from baseline)",
	    histozscore:       true,
	    historange:        [-5, 5]
	},
	{
	    name:              "cmassx",
	    plottitle:         "Center of mass (X direction)",
	    description:       "This metric is calculated as a weighted average of voxel intensities, where each voxel is weighted by its coordinate index in the X, Y, or Z direction.  Head motion in each of the three directions may be reflected as a change in this metric.",
	    demean:            true,
	    meanscale:         false,
	    meanvolmean:       false,
	    meanmaskedvolmean: false,
	    plotpercent:       false,
	    ymin:              -5,
	    ymax:              5,
	    yaxistitle:        "Displacement (in mm) from mean",
	    histozscore:       true,
	    historange:        [-5, 5]
	},
	{
	    name:              "cmassy",
	    plottitle:         "Center of mass (Y direction)",
	    description:       "This metric is calculated as a weighted average of voxel intensities, where each voxel is weighted by its coordinate index in the X, Y, or Z direction.  Head motion in each of the three directions may be reflected as a change in this metric.",
	    demean:            true,
	    meanscale:         false,
	    meanvolmean:       false,
	    meanmaskedvolmean: false,
	    plotpercent:       false,
	    ymin:              -5,
	    ymax:              5,
	    yaxistitle:        "Displacement (in mm) from mean",
	    histozscore:       true,
	    historange:        [-5, 5]
	},
	{
	    name:              "cmassz",
	    plottitle:         "Center of mass (Z direction)",
	    description:       "This metric is calculated as a weighted average of voxel intensities, where each voxel is weighted by its coordinate index in the X, Y, or Z direction.  Head motion in each of the three directions may be reflected as a change in this metric.",
	    demean:            true,
	    meanscale:         false,
	    meanvolmean:       false,
	    meanmaskedvolmean: false,
	    plotpercent:       false,
	    ymin:              -5,
	    ymax:              5,
	    yaxistitle:        "Displacement (in mm) from mean",
	    histozscore:       true,
	    historange:        [-5, 5]
	},
	{
	    name:              "masked_outlier_percent",
	    plottitle:         "Outlier voxel percentages",
	    description:       "This metric is calculated by running the detrended data through the <a href=\"http://afni.nimh.nih.gov/afni/\">AFNI</a> program <tt>3dToutcount</tt>.  This metric shows the percentage of \"outlier\" voxels in each volume.  For a definition of \"outlier\", see the <a href=\"http://afni.nimh.nih.gov/pub/dist/doc/program_help/3dToutcount.html\">documentation for <tt>3dToutcount</tt></a> on the AFNI web site, or run <tt>3dToutcount</tt> without arguments.",
	    demean:            false,
	    meanscale:         false,
	    meanvolmean:       false,
	    meanmaskedvolmean: false,
	    plotpercent:       true,
	    ymin:              0,
	    ymax:              5,
	    yaxistitle:        "Percent of outlier voxels",
	    histozscore:       true,
	    historange:        [-5, 5]
	},
	{
	    name:              "masked_fwhmx",
	    plottitle:         "Full-width half-maximum (FWHM) (X direction)",
	    description:       "This metric shows the estimated FWHM for each volume in X, Y, or Z directions, used as a measure of the \"smoothness\" of the data.",
	    demean:            false,
	    meanscale:         false,
	    meanvolmean:       false,
	    meanmaskedvolmean: false,
	    plotpercent:       false,
	    ymin:              0,
	    ymax:              null,
	    yaxistitle:        null,
	    histozscore:       true,
	    historange:        [-5, 5]
	},
	{
	    name:              "masked_fwhmy",
	    plottitle:         "Full-width half-maximum (FWHM) (Y direction)",
	    description:       "This metric shows the estimated FWHM for each volume in X, Y, or Z directions, used as a measure of the \"smoothness\" of the data.",
	    demean:            false,
	    meanscale:         false,
	    meanvolmean:       false,
	    meanmaskedvolmean: false,
	    plotpercent:       false,
	    ymin:              0,
	    ymax:              null,
	    yaxistitle:        null,
	    histozscore:       true,
	    historange:        [-5, 5]
	},
	{
	    name:              "masked_fwhmz",
	    plottitle:         "Full-width half-maximum (FWHM) (Z direction)",
	    description:       "This metric shows the estimated FWHM for each volume in X, Y, or Z directions, used as a measure of the \"smoothness\" of the data.",
	    demean:            false,
	    meanscale:         false,
	    meanvolmean:       false,
	    meanmaskedvolmean: false,
	    plotpercent:       false,
	    ymin:              0,
	    ymax:              null,
	    yaxistitle:        null,
	    histozscore:       true,
	    historange:        [-5, 5]
	},
	{
	    name:              "spectrummean",
	    plottitle:         "Frequency spectrum (mean over mask)",
	    description:       "A frequency spectrum is calculated for each voxel in the mask and this plot shows the mean power for each frequency across all voxels.",
	    demean:            false,
	    meanscale:         false,
	    meanvolmean:       false,
	    meanmaskedvolmean: false,
	    plotpercent:       false,
	    ymin:              0,
	    ymax:              null,
	    yaxistitle:        null,
	    histozscore:       true,
	    historange:        [-5, 5]
	},
	{
	    name:              "spectrummax",
	    plottitle:         "Frequency spectrum (max over mask)",
	    description:       "A frequency spectrum is calculated for each voxel in the mask and this plot shows the maximum power for each frequency across all voxels.",
	    demean:            false,
	    meanscale:         false,
	    meanvolmean:       false,
	    meanmaskedvolmean: false,
	    plotpercent:       false,
	    ymin:              0,
	    ymax:              null,
	    yaxistitle:        null,
	    histozscore:       true,
	    historange:        [-5, 5]
	}
    ];
    var qakeys = [];
    for (var i = 0; i < qalist.length; i++) {
	qakeys.push(qalist[i].name);
    }
    /* create hash for testing names of qa stats, preload these */
    var qahash = {};
    var preloaded_stats = qakeys;
    for (var i = 0; i < qalist.length; i++) {
	qahash[qalist[i].name] = qalist[i];
    }

    /* order of colors in the scatter/line charts */
    var colors = ['red','blue','green','purple','navy','lime','maroon','black', 'fuchsia', 'gray','olive','aqua','teal']

    /* create hash for summary stats */
    var sumhash = [];
    for ( var k in thisarr=["mean_middle_slice","mean_sfnr_middle_slice","mean_snr_middle_slice","mean_masked_fwhmx","mean_masked_fwhmy",
			    "mean_masked_fwhmz","count_volmean_indiv_masked_z3","count_volmean_indiv_masked_z4","count_velocity_indiv_masked_1percent",
			    "count_velocity_indiv_masked_2percent","count_volmean_indiv_z3","count_volmean_indiv_z4","count_outliers_1percent",
			    "count_outliers_2percent","count_potentially_clipped"] ){
	sumhash[thisarr[k]] = [];
    }


    /* create hash for testing names of slicevariation fields */
    var slicevarhash = [];
    for ( var k in thisarr=["slicevar_data","slicevar_cbar","slicevar_max",
			    "slicevar_min","slicevar_cbar_json"] ) {

	slicevarhash[thisarr[k]] = [];
    }

    /* create hash for testing names of json related fields */
    var jsonimghash = [];
    for ( var k in thisarr=["mean_cbar_json","mean_data_json","sfnr_cbar_json","sfnr_data_json",
			    "stddev_cbar_json","stddev_data_json","mask_data","stddev_max","stddev_min",
			    "mean_max","mean_min","sfnr_min","sfnr_max"] ) {

	jsonimghash[thisarr[k]] = [];
    }

    /* arrays to store data for the page */
    var voldata = [];
    var slicevardata = [];
    var jsondata = [];
    var jsoncbar = [];
    var sumdata = [];
    var localshortnames = [];
    var volmean = null;
    var maskedvolmean = null;

    var reportlabel = null;
    /* get the report label */
    $.ajax({
        type: "GET",
	url: datapath + "reportLabel.txt",
	beforeSend: function(xhr){ if (xhr.overrideMimeType) { xhr.overrideMimeType("text/plain"); } },
	async: false,
	dataType: "text",
	success: function(data) {
	    reportlabel = data.toString().replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
        }
    });
    if (reportlabel != null) {
	$("#reportlabel").html(reportlabel);
	$("#title").html(reportlabel);
    }

    /* get the names of the local xml files */
    $.ajax({
        type: "GET",
	url: datapath + "labelList.txt",
	beforeSend: function(xhr){ if (xhr.overrideMimeType) { xhr.overrideMimeType("text/plain"); } },
	async: false,
	dataType: "text",
	success: function(data) {
            var lines = data.toString().split("\n");
            $.each(lines, function(n, elem){
		if ( elem ) {
		    short_name = elem;
		    //localshortnames.push(elem);                        
		    var fileind = localshortnames.length;
		    localshortnames.push(short_name);

		    //$('#localshortnames').append(elem);

		    if ( !voldata[fileind] ){
			voldata[fileind] = [];
		    }

		    if ( !sumdata[fileind] ){
			sumdata[fileind] = [];
		    }

		    if ( !slicevardata[fileind] ){
			slicevardata[fileind] = [];
		    }

		    if ( !jsondata[fileind] ){
			jsondata[fileind] = [];
		    }

		    for ( k in qahash ){
			if ( !voldata[fileind][k] ){
			    voldata[fileind][k] = [];
			}
		    }

		    for ( k in sumhash ){
			if ( !sumdata[fileind][k] ){
			    sumdata[fileind][k] = [];
			}
		    }

		    for ( k in slicevarhash ){
			if ( !slicevardata[fileind][k] ){
			    slicevardata[fileind][k] = [];
			}
		    }

		    for ( k in jsonimghash ){
			if ( !jsondata[fileind][k] && !( k.match(/(cbar)/) ) ){
			    jsondata[fileind][k] = [];
			}
		    }

		}
	    });
        },
	error: function(jqXHR, textStatus, errorThrown) {
	    $("#errors").append("failed loading: " + datapath + "labelList.txt"  + textStatus.toString() + errorThrown.toString());
        }
    });


    /* read the local json files and store data in object */
    for ( var fileind = 0; fileind < localshortnames.length ; fileind++ ){
	var k = localshortnames[fileind];
	var funcrefs = {};
	for (var name in qahash) {
	    nameobj = { "name": name}
	    funcrefs["json/qa_arraystats_" + name + "_" + k + ".json"] =
		$.proxy(
		    function(data) {
			var i = 0;
			statsdata = data.data;
			for (i = 0; i < statsdata.length; i++) {
			    statsdata[i][0] = parseFloat(statsdata[i][0]);
			    statsdata[i][1] = parseFloat(statsdata[i][1]);
			}
			var summary = data.summary;
			summary.count = parseFloat(summary.count);
			summary.mean = parseFloat(summary.mean);
			summary.stddev = parseFloat(summary.stddev);
			voldata[fileind][this.name] = data;
			//$("#errors").append( "<pre>" + k + " " + this.name + ": " + dump(data) + "</pre>" );
		    },
		    nameobj
		);
	}
	funcrefs["json/qa_scalarstats_" + k + ".json"] =
	    function(data) {
		for (var name in sumhash) {
		    stat = data[name];
		    if (!isNaN(parseFloat(stat)) && isFinite(stat)) {
			// we only allow numbers as scalarstats inputs
			// since these might go unchanged onto the HTML
			// report, and we don't want any malicious strings
			stat = parseFloat(stat);
			sumdata[fileind][name] = stat;
		    }
		    //$("#errors").append( "<pre>" + k + " " + name + ": " + dump(stat) + "</pre>" );
		}
	    };
	funcrefs["json/qa_imagerefs_" + k + ".json"] =
	    function(data) {
		for (var name in slicevarhash) {
		    stat = data[name];
		    if (!isNaN(parseFloat(stat)) && isFinite(stat)) {
			stat = parseFloat(stat);
		    }
		    slicevardata[fileind][name] = stat;
		}
		for (var name in jsonimghash) {
		    stat = data[name];
		    if (!isNaN(parseFloat(stat)) && isFinite(stat)) {
			stat = parseFloat(stat);
		    } else {
			// assume this is a string, and is a file name.
			// prohibit any dangerous slash characters as
			// all these files should be in the same directory.
			if (stat.match(/\//)) {
			    stat = undefined;
			}
		    }
		    jsondata[fileind][name] = stat;
		    if ((/(cbar)/).test(name)) {
			jsoncbar[name] = [];
			jsoncbar[name].push(stat);
		    }
		}
	    };

	for (var thisjson in funcrefs) {
	    $.ajax({
                type: "GET",
		url: datapath + thisjson,
		beforeSend: function(xhr){ if (xhr.overrideMimeType) { xhr.overrideMimeType("application/json"); } },
		async: false,
		dataType: "json",
		success: funcrefs[thisjson],
		error: function(jqXHR, textStatus, errorThrown) {
		    $("#errors").append("failed loading: " + datapath + thisjson  + textStatus.toString() + errorThrown.toString());
		}
	    });
	}
    }

    /* store runs we want to process, we will edit runs2process with checkboxes */
    var runs2process = [];
    for (var fileind = 0; fileind < localshortnames.length; fileind++ ) {
	runs2process.push(fileind);
    }

    //$("#errors").append( "<pre>" + dump(localshortnames) + "</pre>" );

    /* read the local xml files and return requested stat */
    function load_mystat(thisstat,theseruns,labels){
	var mystat = [];

	for ( var runind = 0; runind < theseruns.length; runind++ ) {
            var fileind = theseruns[runind];
	    var k = labels[fileind];
	    var thisjson = "json/qa_arraystats_" + thisstat + "_" + k + ".json"

            $.ajax({
		type: "GET",
		url: datapath + thisjson,
		beforeSend: function(xhr){ if (xhr.overrideMimeType) { xhr.overrideMimeType("application/json"); } },
		async: false,
		dataType: "json",
		success: function(data){
		    mystat[fileind] = []
		    statsdata = data.data;
		    var i = 0;
		    for (i = 0; i < statsdata.length; i++) {
			statsdata[i][0] = parseFloat(statsdata[i][0]);
			statsdata[i][1] = parseFloat(statsdata[i][1]);
		    }
		    summary = data.summary;
		    summary.count = parseFloat(summary.count);
		    summary.mean = parseFloat(summary.mean);
		    summary.stddev = parseFloat(summary.stddev);
		    mystat[fileind][thisstat] = data;
		},
		error: function(jqXHR, textStatus, errorThrown) {
		    $("#errors").append("failed loading: " + datapath + thisjson  + textStatus.toString() + errorThrown.toString());
		}
	    });
	}
	return mystat;
    }


    //$("#errors").html( "<pre>" + dump(voldata) + "</pre>" );
    //$("#errors").append( "<pre>" + dump(jsoncbar) + "</pre>" );
    //$("#errors").append( "<pre>" + dump(slicevardata) + "</pre>" );
    //$("#errors").append( "<pre>" + dump(sumdata) + "</pre>" );

    /* do some calculations */
    function maths(a){
	var r = {sum: 0, mean: 0, count: 0, variance: 0, stddev: 0};
	r.count = a.length;
	r.sum = 0;
	for (var i = 0; i < a.length; i++) {
	    r.sum += a[i][1];
	}
	r.mean = r.sum/r.count;
	var i = a.length;
	
	var v = 0;
	while ( i-- ){
	    v += Math.pow( (a[i][1] - r.mean), 2 );
	}
	r.variance = v / r.count;
	
	r.stddev = Math.sqrt( r.variance );
        
	return r;
    }

    /* return a histogram */
    function get_hist(a, middle, step, plotrange, plotbinnumber) {
	// Return a histogram for plotting.
	// The histogram bins the values X of the array a into the
	// following intervals:
	//   middle+((Z-1)*step) < X <= middle+(Z*step), for integer Z <= 0
	//   middle+(Z*step) >= X > middle+((Z+1)*step), for integer Z >= 0
	// X==middle could have gone in one of two places, I chose the
	// bin above middle arbitrarily.  plotbinnumber==true indicates
	// that bins will be identified by the Z value (i.e. "bin number"),
	// rather than the values represented by the bins.
	// The returned array will have tuples of the form:
	//   [bincenter, numvals], for easy plotting.
	// The returned bin centers will be based on the bin number (Z):
	//   (Z-0.5), for Z <= 0
	//   (Z+0.5), for Z >= 0
	// unless plotbinnumber is false, in which case bin centers are
	// in the same units as the input:
	//   middle+((Z-0.5)*step, for Z <= 0
	//   middle+((Z+0.5)*step, for Z >= 0
	// The plotrange argument [min, max] is in plot units, so if
	// plotbinnumber==true, the range values should also be in
	// bin numbers.  Any values of X outside the specified range
	// are included in the outermost bins (make sure your x-axis
	// clearly labels the outer bins as aggregate intervals).
	if (plotrange[0] >= plotrange[1]) {
	    alert("function get_hist: plotrange[0] (min) >= plotrange[1] (max)!");
	}
	var numbinspos = 0;
	var numbinsneg = 0;
	var valuemin = plotbinnumber ? middle + (plotrange[0] * step) : plotrange[0];
	var valuemax = plotbinnumber ? middle + (plotrange[1] * step) : plotrange[1];
	var hist = [];
	for (var z = 0; valuemin < middle - (z * step); z++) {
	    numbinsneg++;
	    hist.push(0);
	}
	for (var z = 0; middle + (z * step) < valuemax; z++) {
	    numbinspos++;
	    hist.push(0);
	}
	//$("#errors").append( "<pre>" + dump(numbinsneg) + dump(numbinspos) + dump(middle) + dump(step) + dump(plotrange) + "</pre>" );
	var numbins = numbinsneg + numbinspos;
	for (var pt = 0; pt < a.length; pt++) {
	    var val = a[pt][1];
	    var z = (val - middle) / step;
	    // bitwise operator converts a number to an integer,
	    // truncating towards zero (exactly what we want!)
	    var ind = 0;
	    if (z < 0) {
		ind = (z | 0) + numbinsneg - 1;
	    } else {
		ind = (z | 0) + numbinsneg;
	    }
	    if (ind < 0) {
		ind = 0;
	    }
	    if (ind >= numbins) {
		//$("#errors").append( "<pre>" + dump(val) + dump(z) + dump(ind) + "</pre>" );
		ind = numbins - 1;
	    }
	    hist[ind] += 1;
	}
	var tuples = [];
	// skip empty bins
	var beginind = 0;
	for (/* no-op */; beginind < numbins; beginind++) {
	    if (hist[beginind] != 0) { break; }
	}
	var endind = numbins - 1;
	for (/* no-op */; endind >= 0; endind--) {
	    if (hist[endind] != 0) { break; }
	}
	for (var ind = beginind; ind <= endind; ind++) {
	    var bincenter = ind - numbinsneg + 0.5;
	    if (!plotbinnumber) {
		bincenter *= step;
		bincenter += middle;
	    }
	    tuples.push([bincenter, hist[ind]]);
	}
	//$("#errors").append( "<pre>" + dump(tuples) + "</pre>" );
	return tuples;
    }

    function hashSort(a, b){
	return (parseInt(a) - parseInt(b));
    }

    function InsertGraph(thisid,runs,indata,labels) {
	var listI = thisid + "_LI";

	/* adding this way to account for IE */
	var newelem = document.createElement("li")
        newelem.id = listI;

	var thiselem = document.createElement("li")
        var thisin = document.createElement("input")
        thisin.setAttribute("type","checkbox")
        thisin.setAttribute("checked","checked")
        thisin.setAttribute("value",thisid)

        var thisdiv = document.createElement("div")
        thisdiv.setAttribute("class","help")
        var thistext = document.createTextNode("?")
        thisdiv.appendChild(thistext)

        var thislab = document.createElement("label")
        var thistext = document.createTextNode(thisid + ":")
        thislab.appendChild(thistext)

        var thisdesc = document.createElement("div")
        thisdesc.setAttribute("class","description")

        var thisclose = document.createElement("div")
        thisclose.setAttribute("class","close")
        var thistext = document.createTextNode("close")
        thisclose.appendChild(thistext)
        thisdesc.appendChild(thisclose)
        thiselem.appendChild(thisin)
        thiselem.appendChild(thislab)
        thiselem.appendChild(thisdiv)
        thiselem.appendChild(thisdesc)

        var theul = document.getElementById("qaItems")           
        theul.appendChild(thiselem)
        theul.appendChild(newelem)

        ShowGraph(thisid, runs, indata, labels);
    }
    function ShowGraph(thisid,runs,indata,labels) {
	var listI = thisid + "_LI";
	var data = []
        var allvals = {data:[],summary: {}};
	var minvals = []
        var maxvals = []

        var runkeys = [];

	var size = runs.length;

	//$("#errors").append( "<pre> indata: <br />" + dump(indata) + "</pre>" );
	/* extract all the data for this stat */
	for ( var runind = 0; runind < runs.length; runind++) {
	    data.push( indata[runs[runind]][thisid] );
	    runkeys.push(labels[runs[runind]]);
	    allvals.data = allvals.data.concat(indata[runs[runind]][thisid].data);
	}
        
	//minvals.stats = maths(minvals)
	//maxvals.stats = maths(maxvals)
	allvals.summary = maths(allvals.data)

        /* keep volmean stats for later */
        if ( thisid == "volmean" ){
            volmean = allvals.summary;
        } else if ( thisid == "masked_volmean" ){
            maskedvolmean = allvals.summary;
        }

	/* fill in grandmean data from summary sheet */
	if ( thisid.match(/^(volmean|masked_volmean|mean_difference)$/) ) {
	    for ( var k in data ){
		var count3 = 0;
		var count4 = 0;
		var countperc1 = 0;
		var countperc2 = 0;

		rundata = data[k].data;
		for ( var subk = 0; subk < rundata.length; subk++){
		    var absz = Math.abs((rundata[subk][1] - allvals.summary.mean )/allvals.summary.stddev)
		    if ( absz > 4 ){
			++count4;
		    }
		    if ( absz > 3 ) {
			++count3;
		    } 
                    
		    if ( thisid == "mean_difference" ) {
			var perc = (rundata[subk][1]/volmean.mean) * 100
			
			if ( perc > 2 ){
			    ++countperc2;
			}
			if ( perc > 1 ) {
			    ++countperc1;
			} 
		    }
		}

		/* replace the abs val counts */
		if (thisid == "volmean" || thisid == "masked_volmean") {
		    var absz3id = "absz3_" + runkeys[k]
                    var absz4id = "absz4_" + runkeys[k]

                    if (thisid == "masked_volmean") {
                        absz3id = "mask_" + absz3id
                        absz4id = "mask_" + absz4id
                    } 
		    $(".summary #overall_summary " + "#" + absz3id).html(count3)
                    $(".summary #overall_summary " + "#" + absz4id).html(count4)
		}
		/* replace the perc counts */
		if ( thisid == "mean_difference" ) {
		    $(".summary #overall_summary " + "#perc2_" + runkeys[k]).html(countperc2)
                    $(".summary #overall_summary " + "#perc1_" + runkeys[k]).html(countperc1)
		}
	    }
	}

        // remove old elements from list
	$("#" + listI + " *").remove();

	//$("#errors").append( "<pre>"+ dump(data) +"</pre>" )
        /* build a data table */
        var newtable = "<table class=\"data\" id=\"" +  thisid + "_summary_table" +"\"><tbody>\n";
	for ( i=0; i < 4; i++ ){
	    newtable += "<tr>\n";
	    if ( i == 0 ){
		newtable += "<th colspan=\"2\">" + thisid + "</th>"
                for ( var runind = 0; runind < runs.length; runind++) {
                    newtable += "<th>" + runkeys[runind] + "</th>";
                }
	    } else if ( i == 1 ) {
		for ( var si = 0; si < size + 2; si++ ){
		    if ( si == 0 ){
			newtable += "<td rowspan=\"2\">mean:</td>";
		    } else if ( si == 1 ) {
			newtable += "<td>(absolute)</td>";
		    } else {
			newtable += "<td>" + data[si - 2].summary.mean.toFixed(4) + "</td>";
		    }                        
		}
	    } else if ( i == 2 ) {
		for ( var si = 0; si < size + 2; si++ ){
		    if ( si == 0 ){
			continue
		    } else if ( si == 1 ) {
			newtable += "<td>(relative)</td>";
		    } else {
			newtable += "<td>" + (data[si - 2].summary.mean / allvals.summary.mean).toFixed(4) + "</td>";
		    }                        
		}
	    }
	    newtable += "</tr>\n";
	}
	newtable += "</tbody></table>";

	/* insert the new table after the title */
	$("#" + listI).append(newtable);

	function createzoomstruct(parentelem, id) {
	    var zoomtextstyle = 'border: thin dotted #DDD; font-style: italic; font-size: small; color: #088; width: 100%; position: absolute; top: 0px; text-align: center; z-index: 1;';
	    var div = document.createElement('div');
	    div.id = id;
	    div.setAttribute('style', zoomtextstyle);
	    parentelem.appendChild(div);
	    var hdiv = document.createElement('div');
	    var textdiv = document.createElement('div');
	    var vdiv = document.createElement('div');
	    hdiv.setAttribute('class', 'zh');
	    vdiv.setAttribute('class', 'zv');
	    textdiv.setAttribute('class', 'zc');
	    div.appendChild(hdiv);
	    div.appendChild(vdiv);
	    div.appendChild(textdiv); // add it *after* hdiv, vdiv to get alignment correct
	    textdiv.id = id + "_text";
	    var zoomhindiv = document.createElement('div');
	    var zoomvindiv = document.createElement('div');
	    var zoomhoutdiv = document.createElement('div');
	    var zoomvoutdiv = document.createElement('div');
	    zoomhindiv.setAttribute('class', 'abox-l');
	    zoomhoutdiv.setAttribute('class', 'abox-r');
	    zoomvindiv.setAttribute('class', 'abox-l');
	    zoomvoutdiv.setAttribute('class', 'abox-r');
	    zoomhindiv.id = id + "_hin";
	    zoomvindiv.id = id + "_vin";
	    zoomhoutdiv.id = id + "_hout";
	    zoomvoutdiv.id = id + "_vout";
	    hdiv.appendChild(zoomhindiv);
	    hdiv.appendChild(zoomhoutdiv);
	    vdiv.appendChild(zoomvindiv);
	    vdiv.appendChild(zoomvoutdiv);
	    zoomhoutdiv.appendChild(document.createElement('div')).setAttribute('class', 'arr-rl');
	    zoomhoutdiv.appendChild(document.createElement('div')).setAttribute('class', 'arr-lr');
	    zoomhindiv.appendChild(document.createElement('div')).setAttribute('class', 'arr-ll');
	    zoomhindiv.appendChild(document.createElement('div')).setAttribute('class', 'arr-rr');
	    zoomvoutdiv.appendChild(document.createElement('div')).setAttribute('class', 'arr-dt');
	    zoomvoutdiv.appendChild(document.createElement('div')).setAttribute('class', 'arr-ub');
	    zoomvindiv.appendChild(document.createElement('div')).setAttribute('class', 'arr-ut');
	    zoomvindiv.appendChild(document.createElement('div')).setAttribute('class', 'arr-db');
	    return {
		div: $("#" + div.id),
		text: $("#" + textdiv.id),
		hin: $("#" + zoomhindiv.id),
		hout: $("#" + zoomhoutdiv.id),
		vin: $("#" + zoomvindiv.id),
		vout: $("#" + zoomvoutdiv.id)
	    };
	}

	/* create chart HTML elements */
	var thiselem = document.getElementById( listI );
	var chtable = document.createElement('table');
	thiselem.appendChild(chtable);
	var chtr1 = document.createElement('tr');
	chtable.appendChild(chtr1);
	var chtd1a = document.createElement('td');
	chtd1a.setAttribute('style', 'display: block');
	chtr1.appendChild(chtd1a);
	var chdiv1a = document.createElement('div');
	chdiv1a.setAttribute('style', 'display: block; position: relative; height: 300px; width: 600px;');
	chtd1a.appendChild(chdiv1a);
	var chelem1a = document.createElement('div');
	chelem1a.id = thisid + "_" + "chart1";
	chelem1a.setAttribute('style', 'position: absolute; left: 0px; top: 0px; z-index: 0; height: 300px; width: 600px;');
	chdiv1a.appendChild(chelem1a);
	var zoomstruct1a = createzoomstruct(chdiv1a, thisid + "_zoomtext1");
	var chelem1b = document.createElement('td');
	chtr1.appendChild(chelem1b);
	chelem1b.id = thisid + "_" + "hist";
	chelem1b.setAttribute('style', 'height: 300px; width: 300px;');

	/* build the data table */
	var newtable = "<div class=\"hideButton\">show data</div>";
	newtable += "<table class=\"data\" id=\"" +  thisid + "_data_table" +"\" style=\"display:none;\"><tbody>\n";
        
	newtable += "<tr><th>volnum</th>";
	for ( var runind = 0; runind < runs.length; runind++) {
	    newtable += "<th>" + runkeys[runind] + "</th>";
	}
	newtable += "</tr>";
	
	/* fill in the data */
	/* pull out the number of rows */
	var longest_run = null;
	for ( var r in data){
	    if ( data[r].summary.count > longest_run ){
		longest_run = data[r].summary.count;
	    }
	}
	for ( var i = 0; i < parseInt(longest_run); i++ ){
	    newtable += "<tr><td>" + i + "</td>";
	    for ( var si = 0; si < size; si++ ){
		if ( i < data[si].data.length ) {
		    var thisstddev = Math.abs( (data[si].summary.mean - data[si].data[i][1])/data[si].summary.stddev );
		    if ( thisstddev >= 5 ) {
			newtable += "<td class=\"hot\">"
		    } else if ( thisstddev >= 4 ) {
			newtable += "<td class=\"med\">"
		    } else if ( thisstddev >= 3 ) {
			newtable += "<td class=\"mild\">"
		    } else {
			newtable += "<td>";
		    }
		    newtable += parseFloat(data[si].data[i][1]).toFixed(5) + "</td>";
		} else {
		    newtable += "<td></td>";
		}
	    }
	    newtable += "</tr>";
	}
	newtable += "</tbody></table>";
        
	/* insert the data */
	/* NOTE: this has to happen before we draw the charts, otherwise
	 * for some unknown reason, something continually triggers resizing
         * on the charts and they gradually and continually get larger!
	 */
	$("#" + listI).append(newtable);

	//$("#errors").html( "<pre>" + dump( data  ) + "</pre>" );
	//$("#errors").append( "<pre>" + dump( voldata ) + "</pre>" );

	var qaentry = qahash[thisid];

	/* put data in scatter plot form, demean */
	var scatterdata_indiv = [];
	var scatterdata_glob = [];
	var globbase = qaentry.demean ? allvals.summary.mean : 0.0;
	var globscale = 1.0;
	if (qaentry.meanscale) {
	    if (qaentry.meanvolmean) {
		globscale /= volmean.mean;
	    } else if (qaentry.meanmaskedvolmean) {
		globscale /= maskedvolmean.mean;
	    } else {
		globscale /= allvals.summary.mean;
	    }
	    globscale *= qaentry.plotpercent ? 100.0 : 1.0;
	}
	var glob_relative_means = [];
	var indiv_stddevs = [];
	var indiv_scales = [];
	var indiv_means = [];
	for ( var runind = 0; runind < runs.length; runind++) {
	    var indivrun = $.extend(true, [], indata[runind][thisid].data.slice(0));
	    var globrun  = $.extend(true, [], indata[runind][thisid].data.slice(0));
	    var indivbase = qaentry.demean ? indata[runind][thisid].summary.mean : 0.0;
	    var indivscale = 1.0;
	    if (qaentry.meanscale) {
		if (qaentry.meanvolmean) {
		    indivscale /= indata[runind]["volmean"].summary.mean;
		} else if (qaentry.meanmaskedvolmean) {
		    indivscale /= indata[runind]["masked_volmean"].summary.mean;
		} else {
		    indivscale /= indata[runind][thisid].summary.mean;
		}
		indivscale *= qaentry.plotpercent ? 100.0 : 1.0;
	    }
	    for (var sk = 0; sk < indivrun.length; sk++) {
		indivrun[sk][1] = indivscale * (indivrun[sk][1] - indivbase);
		globrun[sk][1] = globscale * (globrun[sk][1] - globbase);
	    }
	    glob_relative_means.push(indivbase - globbase);
	    indiv_means.push(indata[runind][thisid].summary.mean);
	    indiv_stddevs.push(indata[runind][thisid].summary.stddev);
	    indiv_scales.push(indivscale);
	    scatterdata_indiv.push(indivrun)
            scatterdata_glob.push(globrun)                
	}

	/* get the info for the histogram */
	var allscatterdata = [];
	for (var i = 0; i < scatterdata_glob.length; i++) {
	    allscatterdata = allscatterdata.concat(scatterdata_glob[i]);
	}
	var globhisttuples = get_hist(allscatterdata, allvals.summary.mean - globbase, qaentry.histozscore ? allvals.summary.stddev * globscale : 1, qaentry.historange, qaentry.histozscore);
	var indivhisttuples = [];

	for (var i = 0; i < scatterdata_glob.length; i++) {
	    var rundata = scatterdata_indiv[i];
	    indivhisttuples.push([]);
	    var curhist = [];
	    for (var z = 0; z < 12; z++) {
		curhist.push(0);
	    }
	    var scale = indiv_scales[i];
	    var stddev = indiv_stddevs[i];
	    indivhisttuples[i] = get_hist(rundata, 0, qaentry.histozscore ? stddev * scale : 1, qaentry.historange, qaentry.histozscore);
	}

	function addStddevPlotLines(chart, axis, prefix, mean, stddev) {
	    var thiselem = chart.container;
	    var elemheight = null;
	    if (typeof thiselem.clip !== "undefined") {
		elemheight = thiselem.clip.height;
	    } else {
		if (thiselem.style.pixelHeight) {
		    elemheight = thiselem.style.pixelHeight;
		} else {
		    elemheight = thiselem.offsetHeight;
		}
	    }
	    var plotpixelheight = elemheight;
	    var axisextremes = axis.getExtremes();
	    var axisdataheight = axisextremes.max - axisextremes.min;
	    var zstep = Math.ceil(15 / ((stddev / axisdataheight) * plotpixelheight));
	    var zmax = Math.floor(5 / zstep) * zstep;
	    for (var z = -1 * zmax; z <= zmax; z += zstep) {
		axis.addPlotLine({
                    id: prefix + "z" + z.toString(),
		    color: "red",
		    width: 1,
		    dashStyle: "Dot",
		    label: {
			//rotation: (z / Math.abs(z)) * -30,
                        text: "z = " + z.toString(),
			x: -1,
			align: "right",
			y: 4,
			textAlign: "left"
		    },
		    value: [mean + (z * stddev)]
		});
	    }
	}

	// do histogram first as we refer to it in legendclick
	var histchart = new Highcharts.Chart({
	    credits: { enabled: false },
            chart: {
                renderTo: chelem1b.id,
                type: "column",
                reflow: false,
                width: 300, /* needed for IE8?? */
                style: {
                    width: 300, /* needed for IE8?? */
                    position: "relative"
                }
            },
            plotOptions: {
                column: {
                    pointPadding: 0,
                    groupPadding: 0
                }
            },
            series: [{
		id: 'series-hist',
		name: "All data",
		data: globhisttuples
	    }],
            title: {
                text: null
            },
            xAxis: {
                tickInterval: 1,
                labels: {
                    formatter: function() {
                        if (this.value < -5) { return ""; }
                        if (this.vlaue > 5) { return ""; }
                        if (this.value == -5) { return "<=-5"; }
                        if (this.value == 5) { return "5=>"; }
                        return this.value;
                    }
                },
                title: { text: "# of stddevs from mean" },
                min: -5,
                max: 5
            }
        });

	var stdyaxis = {
	    min: qaentry.ymin,
	    max: qaentry.ymax,
	    startOnTick: false,
	    endOnTick: false,
	    tickPixelInterval: 36,
	    title: { text: qaentry.yaxistitle }
	};
	var legendclickaux = function(event, this2, indivmeans, indivstddevs, globmean, globstddev, dohist) {
	    var seriesIndex = this2.index;
	    var series = this2.chart.series;
	    var yaxis = this2.chart.yAxis[0];
	    var othersinvisible = false;
	    for (var i = 0; i < series.length; i++) {
		if (i != seriesIndex && !series[i].visible) { othersinvisible = true; break; }
	    }
	    var fromindiv = !this2.visible || othersinvisible;
	    var toindiv = !this2.visible || !othersinvisible;
	    // remove old data
	    if (fromindiv) {
		// changing to another series or resetting to global data
		// remove individual stddev lines, histogram data
		for (var i = 0; i < series.length; i++) {
		    if (series[i].visible) {
			for (var z = -5; z <= 5; z++) {
			    yaxis.removePlotLine("s" + i.toString() + "z" + z.toString());
			}
		    }
		}
	    } else {
		// changing from global data, remove global stddev lines
		for (var z = -5; z <= 5; z++) {
		    yaxis.removePlotLine("gz" + z.toString());
		}
	    }
	    // remove histogram data
	    if (dohist) {
		histchart.get('series-hist').remove(false);
	    }
	    if (!toindiv) {
		// going to global data;
		// set all series to visible, add global stddev lines,
		// reset histogram to global data
		for (var i = 0; i < series.length; i++) {
		    if (!series[i].visible) {
			series[i].show();
		    }
		}
		if (dohist) {
		    histchart.addSeries({
                        id: 'series-hist',
                        name: "All data",
                        data: globhisttuples
                    });
		}
		if (globmean != null && globstddev != null) {
		    addStddevPlotLines(this2.chart, yaxis, "g", globmean, globstddev);
		}
		return false;
	    }
	    // changing to an individual series
	    // turn off all but selected
	    for (var i = 0; i < series.length; i++) {
		if (series[i].index == seriesIndex) {
		    series[i].visible ?
			0/*no-op*/ :
			series[i].show();
		} else {
		    series[i].visible ?
			series[i].hide() :
			0/*no-op*/;
		}
	    }
	    // add indiv stddev lines,
	    // replace histogram with indiv data
	    addStddevPlotLines(this2.chart, yaxis, "s" + seriesIndex.toString(), indivmeans[seriesIndex], indivstddevs[seriesIndex]);
	    if (dohist) {
		histchart.addSeries({
		    id: 'series-hist',
		    name: runkeys[seriesIndex],
		    data: indivhisttuples[seriesIndex]
		});
	    }
	    return false;
	}

	// Support functions for zooming with mouse scroll wheel, and
	// panning by dragging the mouse.
	var setZoomAux = function(obj, zoomRatioH, zoomRatioV) {
	    var xMin = obj.chart.xAxis[0].getExtremes().min;
	    var xMax = obj.chart.xAxis[0].getExtremes().max;
	    var xWidth = xMax - xMin;
	    var xOffset = (1 - zoomRatioH) * xWidth / 2.0;
	    var yMin = obj.chart.yAxis[0].getExtremes().min;
	    var yMax = obj.chart.yAxis[0].getExtremes().max;
	    var yWidth = yMax - yMin;
	    var yOffset = (1 - zoomRatioV) * yWidth / 2.0;
	    obj.chart.xAxis[0].setExtremes(xMin - xOffset, xMax + xOffset);
	    obj.chart.yAxis[0].setExtremes(yMin - yOffset, yMax + yOffset);
	};
	function createPanningHandlers(elem, chart, chartWidth, chartHeight, zoomstruct) {
	    var obj = {
		chart: chart,
		zoomFactor: 0.1,
		lastX: null,
		lastY: null,
		mouseDown: null,
		zoomOn: false,
		zoomstruct: zoomstruct,
		hindown: false,
		houtdown: false,
		vindown: false,
		voutdown: false
	    };
	    function doZoom() {
		if (obj.hindown) {
		    setZoomAux(obj, 1 + obj.zoomFactor, 1);
		} else if (obj.houtdown) {
		    setZoomAux(obj, 1 - obj.zoomFactor, 1);
		} else if (obj.vindown) {
		    setZoomAux(obj, 1, 1 + obj.zoomFactor);
		} else if (obj.voutdown) {
		    setZoomAux(obj, 1, 1 - obj.zoomFactor);
		} else {
		    // no buttons down
		    return;
		}
		setTimeout(doZoom, 50);
	    }
	    if (obj.zoomstruct) {
		obj.zoomstruct.hin.mouseup(function() {
		    obj.hindown = false;
		    obj.zoomstruct.hin.css("border-style", "outset");
		    return false;
		});
		obj.zoomstruct.hout.mouseup(function() {
		    obj.houtdown = false;
		    obj.zoomstruct.hout.css("border-style", "outset");
		    return false;
		});
		obj.zoomstruct.vin.mouseup(function() {
		    obj.vindown = false;
		    obj.zoomstruct.vin.css("border-style", "outset");
		    return false;
		});
		obj.zoomstruct.vout.mouseup(function() {
		    obj.voutdown = false;
		    obj.zoomstruct.vout.css("border-style", "outset");
		    return false;
		});
		obj.zoomstruct.hin.mousedown(function() {
		    obj.hindown = true;
		    obj.zoomstruct.hin.css("border-style", "inset");
		    doZoom();
		    return false;
		});
		obj.zoomstruct.hout.mousedown(function() {
		    obj.houtdown = true;
		    obj.zoomstruct.hout.css("border-style", "inset");
		    doZoom();
		    return false;
		});
		obj.zoomstruct.vin.mousedown(function() {
		    obj.vindown = true;
		    obj.zoomstruct.vin.css("border-style", "inset");
		    doZoom();
		    return false;
		});
		obj.zoomstruct.vout.mousedown(function() {
		    obj.voutdown = true;
		    obj.zoomstruct.vout.css("border-style", "inset");
		    doZoom();
		    return false;
		});
	    }
	    elem.mousewheel(function(objEvent, delta, deltaX, deltaY) {
		// zoom proportional to square of delta, but retain sign.
		// so, if you scroll faster, the zooms accelerates, at least
		// in theory.
		if (obj.zoomOn == false) {
		    // let other handlers take care of this
		    return true;
		}
		setZoomAux(obj, 1 + (Math.abs(delta) * delta * obj.zoomFactor));
		return false;
	    });
	    elem.mouseup(function() {
		obj.mouseDown = 0;
	    });
	    elem.mousemove(function(e) {
		if (obj.mouseDown == 1) {
		    if (e.pageX > obj.lastX) {
			var diff = e.pageX - obj.lastX;
			var xExtremes = obj.chart.xAxis[0].getExtremes();
			diff = (xExtremes.max - xExtremes.min) * diff / chartWidth;
			obj.chart.xAxis[0].setExtremes(xExtremes.min - diff, xExtremes.max - diff);
		    }
		    else if (e.pageX < obj.lastX) {
			var diff = obj.lastX - e.pageX;
			var xExtremes = obj.chart.xAxis[0].getExtremes();
			diff = (xExtremes.max - xExtremes.min) * diff / chartWidth;
			obj.chart.xAxis[0].setExtremes(xExtremes.min + diff, xExtremes.max + diff);
		    }

		    if (e.pageY > obj.lastY) {
			var diff = 1 * (e.pageY - obj.lastY);
			var yExtremes = obj.chart.yAxis[0].getExtremes();
			diff = (yExtremes.max - yExtremes.min) * diff / chartHeight;
			obj.chart.yAxis[0].setExtremes(yExtremes.min + diff, yExtremes.max + diff);
		    }
		    else if (e.pageY < obj.lastY) {
			var diff = 1 * (obj.lastY - e.pageY);
			var yExtremes = obj.chart.yAxis[0].getExtremes();
			diff = (yExtremes.max - yExtremes.min) * diff / chartHeight;
			obj.chart.yAxis[0].setExtremes(yExtremes.min - diff, yExtremes.max - diff);
		    }
		}
		obj.lastX = e.pageX;
		obj.lastY = e.pageY;
		return false;
	    });
	}
   
	var globmean = allvals.summary.mean;
	var globstddev = allvals.summary.stddev;
	var scaledindivmeans1 = indiv_means.slice(0);
	var scaledindivstddevs1 = indiv_stddevs.slice(0);
	if (qaentry.demean) {
	    scaledindivmeans1 = glob_relative_means.slice(0);
	    globmean = 0;
	}
	if (qaentry.meanscale) {
	    for (var i = 0; i < glob_relative_means.length; i++) {
		scaledindivmeans1[i] *= indiv_scales[i];
		scaledindivstddevs1[i] *= indiv_scales[i];
	    }
	    globstddev *= globscale;
	}
	var legendclick1 = function(event) {
	    return legendclickaux(event, this, scaledindivmeans1, scaledindivstddevs1, globmean, globstddev, true);
	}
	var series = [];
	for (var i = 0; i < scatterdata_glob.length; i++) {
	    series.push({
                data: scatterdata_glob[i],
		name: runkeys[i],
		marker: { enabled : false },
		shadow: false,
		events: { legendItemClick: legendclick1 }
	    });
	}

	var chart = new Highcharts.Chart({
	    credits: { enabled: false },
            chart: {
                renderTo: chelem1a.id,
                type: "line",
                alignTicks: false,
                marginRight: "30",
                reflow: false,
                width: 600, /* needed for IE8?? */
                style: {
                    width: 600, /* needed for IE8?? */
                    position: "relative"
                }
            },
            series: series,
            tooltip: {
                enabled: false
            },
            title: {
                text: qaentry.plottitle
            },
            subtitle: {
                text: (qaentry.meanscale ? ("baseline (plotted at 0) is mean across all series" + (qaentry.meanvolmean ? "' <i>volume means</i>" : (qaentry.meanmaskedvolmean ? "' <i>masked volume means</i>" : ""))) : "")
            },
            yAxis: stdyaxis
        });
	createPanningHandlers($("#" + chelem1a.id), chart, 600, 300, zoomstruct1a);
	addStddevPlotLines(chart, chart.yAxis[0], "g", globmean, globstddev);

	if (qaentry.demean) {
	    var chtr2 = document.createElement('tr');
	    chtable.appendChild(chtr2);
	    var chtd2a = document.createElement('td');
	    chtd2a.setAttribute('style', 'display: block; position: relative; height: 300px; width: 600px;');
	    chtr2.appendChild(chtd2a);
	    var chdiv2a = document.createElement('div');
	    chdiv2a.setAttribute('style', 'display: block');
	    chtd2a.appendChild(chdiv2a);
	    var chelem2a = document.createElement('div');
	    chelem2a.id = thisid + "_" + "chart2";
	    chelem2a.setAttribute('style', 'position: absolute; position: relative; left: 0px; top: 0px; z-index: 0; height: 300px; width: 600px;');
	    chdiv2a.appendChild(chelem2a);
	    var zoomstruct2a = createzoomstruct(chdiv2a, thisid + "_zoomtext2");
	    var chelem2b = document.createElement('td');
	    chtr2.appendChild(chelem2b);
	    
	    var scaledindivmeans2 = glob_relative_means.slice(0);
	    var scaledindivstddevs2 = indiv_stddevs.slice(0);
	    for (var i = 0; i < glob_relative_means.length; i++) {
		scaledindivmeans2[i] = 0;
		scaledindivstddevs2[i] *= indiv_scales[i];
	    }
	    var legendclick2 = function(event) {
		return legendclickaux(event, this, scaledindivmeans2, scaledindivstddevs2, null, null, false);
	    }
	    var series = [];
	    for (var i = 0; i < scatterdata_indiv.length; i++) {
		series.push({
                    data: scatterdata_indiv[i],
		    name: runkeys[i],
		    marker: { enabled : false },
		    shadow: false,
		    events: { legendItemClick: legendclick2 }
		});
	    }
	    
	    var chart = new Highcharts.Chart({
		credits: { enabled: false },
                chart: {
                    renderTo: chelem2a.id,
                    type: "line",
                    marginRight: "30",
                    reflow: false,
                    width: 600, /* needed for IE8?? */
                    style: {
                        width: 600, /* needed for IE8?? */
                        position: "relative"
                    }
                },
                series: series,
                tooltip: {
                    enabled: false
                },
                title: {
                    text: qaentry.plottitle
                },
                subtitle: {
                    text: (qaentry.meanscale ? "each series' baseline is its mean, plotted at 0" : "")
                },
                yAxis: stdyaxis
            });
	    createPanningHandlers($("#" + chelem2a.id), chart, 600, 300, zoomstruct2a);
	}
    }

    /* build the summary table */
    var runkeys = localshortnames;

    var newtable = "<li><table class=\"data\" id=\"overall_summary\"><tbody>\n";

    var size = runs2process.length;

    for ( i=0; i < 23; i++ ){
	newtable += "<tr>\n";
	if ( i == 0 ){
	    newtable += "<th colspan=\"3\"></th>"
            for ( var fileind = 0; fileind < runs2process.length; fileind++) {
                newtable += "<th>" + localshortnames[fileind] + "</th>";
            }
	} else if ( i == 1 ) {
	    for ( var si = 0; si < size + 3; si++ ){
		if ( si == 0 ){
		    newtable += "<td>input</td>";
		} else if ( si == 1 ) {
		    newtable += "<td colspan=\"2\"># potentially-clipped voxels</td>";
		} else if ( si == 2 ){
		    continue
		} else {
		    var val = sumdata[si - 3]["count_potentially_clipped"];
		    if ( val != 0 ){
			newtable += "<td class=\"med\">"
		    } else {
			newtable += "<td>"
		    }              
		    newtable += val + "</td>";
		}                        
	    }
	} else if ( i == 2 ) {
	    for ( var si = 0; si < size + 3; si++ ){
		if ( si == 0 ){
		    newtable += "<td rowspan=\"6\">input</td>";
		} else if ( si == 1 ) {
		    newtable += "<td rowspan=\"2\"># vols. with mean intensity abs. z-score > 3</td>";
		} else if ( si == 2 ) {
		    newtable += "<td>individual</td>";
		} else {
		    newtable += "<td>"+ sumdata[si - 3]["count_volmean_indiv_z3"] +"</td>";
		}                       
	    }
	} else if ( i == 3 ) {
	    for ( var si = 0; si < size + 3; si++ ){
		if ( si < 2 ){
		    continue
		} else if ( si == 2 ) {
		    newtable += "<td>rel. to grand mean</td>";
		} else {
		    newtable += "<td id=\"absz3_" + runkeys[ si - 3 ] + "\"></td>";
		}
	    }
	} else if ( i == 4 ) {
	    for ( var si = 0; si < size + 3; si++ ){
		if ( si < 1 ){
		    continue
		} else if ( si == 1 ) {
		    newtable += "<td rowspan=\"2\"># vols. with mean intensity abs. z-score > 4</td>";
		} else if ( si == 2 ) {
		    newtable += "<td>individual</td>";
		} else {
		    newtable += "<td>"+ sumdata[si - 3]["count_volmean_indiv_z4"] +"</td>";
		}                       
	    }
	} else if ( i == 5 ) {
	    for ( var si = 0; si < size + 3; si++ ){
		if ( si < 2 ){
		    continue
		} else if ( si == 2 ) {
		    newtable += "<td>rel. to grand mean</td>";
		} else {
		    newtable += "<td id=\"absz4_" + runkeys[ si - 3 ] + "\"></td>";
		}
	    }
	} else if ( i == 6 ) {
	    for ( var si = 0; si < size + 3; si++ ){
		if ( si < 1 ){
		    continue
		} else if ( si == 1 ) {
		    newtable += "<td colspan=\"2\"># vols. with mean volume difference > 1%</td>";
		} else if ( si == 2 ) {
		    continue
		} else {
		    newtable += "<td id=\"perc1_" + runkeys[ si - 3 ] + "\"></td>";
		}                       
	    }
	} else if ( i == 7 ) {
	    for ( var si = 0; si < size + 3; si++ ){
		if ( si < 1 ){
		    continue
		} else if ( si == 1 ) {
		    newtable += "<td colspan=\"2\"># vols. with mean volume difference > 2%</td>";
		} else if ( si == 2 ) {
		    continue
		} else  {
		    newtable += "<td id=\"perc2_" + runkeys[ si - 3 ] + "\"></td>";
		}                       
	    }
	} else if ( i == 8 ) {
	    for ( var si = 0; si < size + 3; si++ ){
		if ( si == 0 ){
		    newtable += "<td rowspan=\"3\">masked</td>";
		} else if ( si == 1 ) {
		    newtable += "<td rowspan=\"3\">mean FWHM</td>";
		} else if ( si == 2 ){
		    newtable += "<td>X</td>";                        
		} else {
		    newtable += "<td>" + sumdata[si - 3]["mean_masked_fwhmx"] + " </td>";
		}                        
	    }
	} else if ( i == 9 ) {
	    for ( var si = 0; si < size + 3; si++ ){
		if ( si < 2 ){
		    continue
		} else if ( si == 2 ) {
		    newtable += "<td>Y</td>";
		} else {
		    newtable += "<td>" + sumdata[si - 3]["mean_masked_fwhmy"] + " </td>";
		}
	    }
	} else if ( i == 10 ) {
	    for ( var si = 0; si < size + 3; si++ ){
		if ( si < 2 ){
		    continue
		} else if ( si == 2 ) {
		    newtable += "<td>Z</td>";
		} else {
		    newtable += "<td>" + sumdata[si - 3]["mean_masked_fwhmz"] + " </td>";
		}
	    }
	} else if ( i == 11 ) {
	    for ( var si = 0; si < size + 3; si++ ){
		if ( si == 0 ){
		    newtable += "<td rowspan=\"11\">masked, detrended</td>";
		} else if ( si == 1 ) {
		    newtable += "<td rowspan=\"2\"># vols. with mean intensity abs. z-score > 3</td>";
		} else if ( si == 2 ){
		    newtable += "<td>individual</td>";                        
		} else {
		    newtable += "<td>"+ sumdata[si - 3]["count_volmean_indiv_masked_z3"] +"</td>";
		}                        
	    }
	} else if ( i == 12 ) {
	    for ( var si = 0; si < size + 3; si++ ){
		if ( si < 2 ){
		    continue
		} else if ( si == 2 ) {
		    newtable += "<td>rel. to grand mean</td>";
		} else {
		    newtable += "<td id=\"mask_absz3_" + runkeys[ si - 3 ] + "\"></td>";
		}
	    }
	} else if ( i == 13 ) {
	    for ( var si = 0; si < size + 3; si++ ){
		if ( si < 1 ){
		    continue
		} else if ( si == 1 ) {
		    newtable += "<td rowspan=\"2\"># vols. with mean intensity abs. z-score > 4</td>";
		} else if ( si == 2 ) {
		    newtable += "<td>individual</td>";
		} else {
		    newtable += "<td>"+ sumdata[si - 3]["count_volmean_indiv_masked_z4"] +"</td>";
		}                       
	    }
	} else if ( i == 14 ) {
	    for ( var si = 0; si < size + 3; si++ ){
		if ( si < 2 ){
		    continue
		} else if ( si == 2 ) {
		    newtable += "<td>rel. to grand mean</td>";
		} else {
		    newtable += "<td id=\"mask_absz4_" + runkeys[ si - 3 ] + "\"></td>";
		}
	    }
	} else if ( i == 15 ) {
	    for ( var si = 0; si < size + 3; si++ ){
		if ( si < 1 ){
		    continue
		} else if ( si == 1 ) {
		    newtable += "<td colspan=\"2\"># vols. with running difference > 1%</td>";
		} else if ( si == 2 ) {
		    continue
		} else {
		    newtable += "<td>"+ sumdata[si - 3]["count_velocity_indiv_masked_1percent"] +"</td>";
		}                       
	    }
	} else if ( i == 16 ) {
	    for ( var si = 0; si < size + 3; si++ ){
		if ( si < 1 ){
		    continue
		} else if ( si == 1 ) {
		    newtable += "<td colspan=\"2\"># vols. with running difference > 2%</td>";
		} else if ( si == 2 ) {
		    continue
		} else  {
		    newtable += "<td>"+ sumdata[si - 3]["count_velocity_indiv_masked_2percent"] +"</td>";
		}                       
	    }
	} else if ( i == 17 ) {
	    for ( var si = 0; si < size + 3; si++ ){
		if ( si < 1 ){
		    continue
		} else if ( si == 1 ) {
		    newtable += "<td colspan=\"2\"># vols. with > 1% outlier voxels</td>";
		} else if ( si == 2 ) {
		    continue
		} else {
		    newtable += "<td>"+ sumdata[si - 3]["count_outliers_1percent"] +"</td>";
		}                       
	    }
	} else if ( i == 18 ) {
	    for ( var si = 0; si < size + 3; si++ ){
		if ( si < 1 ){
		    continue
		} else if ( si == 1 ) {
		    newtable += "<td colspan=\"2\"># vols. with > 2% outlier voxels</td>";
		} else if ( si == 2 ) {
		    continue
		} else  {
		    newtable += "<td>"+ sumdata[si - 3]["count_outliers_2percent"] +"</td>";
		}                       
	    }
	} else if ( i == 19 ) {
	    for ( var si = 0; si < size + 3; si++ ){
		if ( si < 1 ){
		    continue
		} else if ( si == 1 ) {
		    newtable += "<td colspan=\"2\">mean (ROI in middle slice)</td>";
		} else if ( si == 2 ) {
		    continue
		} else  {
		    newtable += "<td>" + sumdata[si - 3]["mean_middle_slice"]  +"</td>";
		}                       
	    }
	} else if ( i == 20 ) {
	    for ( var si = 0; si < size + 3; si++ ){
		if ( si < 1 ){
		    continue
		} else if ( si == 1 ) {
		    newtable += "<td colspan=\"2\">mean SNR (ROI in middle slice)</td>";
		} else if ( si == 2 ) {
		    continue
		} else {
		    newtable += "<td>" + sumdata[si - 3]["mean_snr_middle_slice"]  +"</td>";
		}                       
	    }
	} else if ( i == 21 ) {
	    for ( var si = 0; si < size + 3; si++ ){
		if ( si < 1 ){
		    continue
		} else if ( si == 1 ) {
		    newtable += "<td colspan=\"2\">mean SFNR (ROI in middle slice)</td>";
		} else if ( si == 2 ) {
		    continue
		} else  {
		    newtable += "<td>" + sumdata[si - 3]["mean_sfnr_middle_slice"]  +"</td>";
		}                       
	    }
	} else if ( i == 22 ) {
	    for ( var si = 0; si < size + 3; si++ ){
		if ( si == 0 ){
		    newtable += "<td>runs to include in plots: "
		} else if ( si == 1 ){
		    continue
		} else if ( si == 2 ) {
		    newtable += "<td colspan=\"2\" style=\"text-align:center;\"><div id=\"reload\" class=\"button\">reload</div></td>";
		} else  {
		    newtable += "<td style=\"text-align:center;\"><input name=\"inc_runs[]\" type=\"checkbox\" checked=\"checked\" value=\"" + (si - 3).toString() + "\"></input></td>";
		}                       
	    }
	}


	newtable += "</tr>\n";
    }
    newtable += "</tbody></table></li>";

    /* insert the new table after the title */
    $(".summary").append(newtable);
    //delete sumdata, newtable;
    sumdata = null;
    newtable = null;

    //dynamically build the UL with canvas items and run the rgraph
    for ( var i = 0; i < preloaded_stats.length; i++ ) {
	k = preloaded_stats[i];
	/* plot the graphs in the canvases */
	var missingdata = false;
	for (var fileind = 0; fileind < localshortnames.length; fileind++) {
	    if (voldata[fileind][k].length == 0) {
		missingdata = true;
		break;
	    }
	}
	if (missingdata) {
	    continue;
	}
	InsertGraph(k,runs2process,voldata,localshortnames);			
    }


    /* build slice variation data table */
    for ( var fileind = 0; fileind < slicevardata.length; fileind++ ){
	k = runkeys[fileind];

	var cbar = return_json_contents(slicevardata[fileind]['slicevar_cbar_json'],fileind,k,null);

	var newelem = "<li id=\"slicevar_" + k + "\">" + k + "<br>";
	newelem += "<table class=\"data\" style=\"width:384px;\"><tbody>";
	newelem += "<tr><td style=\"text-align:left;\">0</td>";
	newelem += "<td style=\"text-align:right;\">30</td></tr>";
	newelem += "<tr><td colspan=\"2\"><img src=\""+ cbar.data + "\"></img></td></tr>";
	newelem += "<tr><td>image min:" + slicevardata[fileind].slicevar_min + "</td>";
	newelem += "<td>image max:" + slicevardata[fileind].slicevar_max + "</td></tr>";
	newelem += "</tbody></table>";
        
	newelem += "<img src=\"" + datapath + slicevardata[fileind].slicevar_data + "\"></img></li>";
	
	/* insert the new table */
	$("ul.slicevar").append( newelem );
	/* insert link in navigation */
	$("#slicevar_runs").append( "<li>" + k + "</li>" )
    }



    /* pull info from the json data, if older IE return image links instead of base64 */
    function return_json_contents(thisjson, fileind, fullname, whichstat){
	var returnObj = { data: null, disp_minval: null, disp_maxval: null, act_minval: null, act_maxval: null };

	if ( whichstat ) {
	    returnObj.act_minval = jsondata[fileind][whichstat + "_min"];               
	    returnObj.act_maxval = jsondata[fileind][whichstat + "_max"];
	}

	$.ajax({
            type: "GET",
	    url: datapath + thisjson,
	    beforeSend: function(xhr){ if (xhr.overrideMimeType) { xhr.overrideMimeType("application/json"); } },
	    async: false,
	    dataType: "json",
	    success: function(data){
                if ( !useSimple ) {
                    returnObj.data = "data:image/gif;base64," + data.data;
                } else {
                    returnObj.data = datapath + String(thisjson).replace(/(.json)/gi,"");
                }

                returnObj.disp_minval = data.minval;
                returnObj.disp_maxval = data.maxval;
            },
	    error: function(jqXHR, textStatus, errorThrown) {
		$("#errors").append("failed loading: " + datapath + thisjson  + textStatus.toString() + errorThrown.toString());
	    }
	});

	return returnObj;
    }


    /* display the mean,stddev,mask,sfnr images */
    for ( var fileind = 0; fileind < jsondata.length; fileind++ ) {
	k = runkeys[fileind];
	$("ul.means").append("<li id=\"means_" + k + "\">" + k +":<br></li>");

	var meancbar = return_json_contents(jsoncbar['mean_cbar_json'],fileind,k,null);
	var stddevcbar = return_json_contents(jsoncbar['stddev_cbar_json'],fileind,k,null);
	var meandata = return_json_contents(jsondata[fileind]['mean_data_json'],fileind,k,'mean');
	var stddevdata = return_json_contents(jsondata[fileind]['stddev_data_json'],fileind,k,'stddev');

	var outtable = "<table class=\"means\"><tbody>";
	outtable += "<tr>";
	outtable += "<th colspan=\"2\">mean</td>";
	outtable += "<td style=\"width:20px;\"></td>";
	outtable += "<th colspan=\"2\">standard deviation</td>";
	outtable += "</tr>";
	outtable += "<tr>";
	outtable += "<td><span class=\"mean_cbarmin\">" + meandata.disp_minval + "</span></td>";
	outtable += "<td style=\"text-align: right;\"><span class=\"mean_cbarmax\">"+ meandata.disp_maxval +"</span></td>";
	outtable += "<td></td>"
	outtable += "<td><span class=\"stddev_cbarmin\">" + stddevdata.disp_minval +"</span></td>";
	outtable += "<td style=\"text-align: right;\"><span class=\"stddev_cbarmax\">" + stddevdata.disp_maxval + "</span></td>";
	outtable += "<td></td>";
	outtable += "</tr>";
	outtable += "<tr>";
	outtable += "<td class=\"cbar\" colspan=\"2\"><img class=\"scalable\" src=\"" + meancbar.data + "\"></td>";
	outtable += "<td></td>";
	outtable += "<td class=\"cbar\" colspan=\"2\"><img class=\"scalable\" src=\"" + stddevcbar.data +"\"></td>";
	outtable += "</tr>";

	/* display */
	outtable += "<tr style=\"display:none;\">";
	outtable += "<td>image min: <span class=\"disp_mean_imgmin\">" + meandata.disp_minval + "</span></td>";
	outtable += "<td style=\"text-align: right;\">image max: <span class=\"disp_mean_imgmax\">"+ meandata.disp_maxval +"</span></td>";
	outtable += "<td></td>";
	outtable += "<td>image min: <span class=\"disp_stddev_imgmin\">" + stddevdata.disp_minval + "</span></td>";
	outtable += "<td style=\"text-align: right;\">image max: <span class=\"disp_stddev_imgmax\">"+ stddevdata.disp_maxval +"</span></td>";
	outtable += "</tr>";

	/* actual image */
	outtable += "<tr>";
	outtable += "<td>image min: <span class=\"mean_imgmin\">" + meandata.act_minval + "</span></td>";
	outtable += "<td style=\"text-align: right;\">image max: <span class=\"mean_imgmax\">"+ meandata.act_maxval +"</span></td>";
	outtable += "<td></td>";
	outtable += "<td>image min: <span class=\"stddev_imgmin\">" + stddevdata.act_minval + "</span></td>";
	outtable += "<td style=\"text-align: right;\">image max: <span class=\"stddev_imgmax\">"+ stddevdata.act_maxval +"</span></td>";
	outtable += "</tr>";

	outtable += "<tr>";
	outtable += "<td colspan=\"2\"><img id=\"mean_" + k + "\" class=\"scalable mean_img\" src=\"" + meandata.data + "\"></td>";
	outtable += "<td></td>";
	outtable += "<td colspan=\"2\"><img id=\"stddev_" + k + "\" class=\"scalable stddev_img\" src=\"" + stddevdata.data + "\"></td>";
	outtable += "</tr>";
	outtable += "<tr>";
	outtable += "</tr>";
	outtable += "<tr>";
	outtable += "<th colspan=\"2\">sfnr (detrended)</th>";
	outtable += "<td></td>";
	outtable += "<th colspan=\"2\">mask</th>";
	outtable += "</tr>";
	//outtable += "<tr colspan=\"5\"></tr>";
	outtable += "<tr>";


	var sfnrcbar = return_json_contents(jsoncbar['sfnr_cbar_json'],fileind,k,null);
	var sfnrdata = return_json_contents(jsondata[fileind]['sfnr_data_json'],fileind,k,'sfnr');

	outtable += "<td><span class=\"sfnr_cbarmin\">"+ sfnrdata.disp_minval +"</span></td>";
	outtable += "<td style=\"text-align: right;\"><span class=\"sfnr_cbarmax\">" + sfnrdata.disp_maxval + "</span></td>";
	outtable += "<td colspan=\"4\"></td>";
	outtable += "</tr>";
	outtable += "<tr>";
	outtable += "<td class=\"cbar\" colspan=\"2\"><img class=\"scalable\" src=\"" + sfnrcbar.data + "\"></td>";
	outtable += "<td colspan=\"4\"></td>";
	outtable += "</tr>";

	/* display */
	outtable += "<tr style=\"display:none;\">";
	outtable += "<td>image min: <span class=\"disp_sfnr_imgmin\">"+ sfnrdata.disp_minval +"</span></td>";
	outtable += "<td style=\"text-align: right;\">image max: <span class=\"disp_sfnr_imgmax\">" + sfnrdata.disp_maxval + "</span></td>";
	outtable += "<td colspan=\"3\"></td>";
	outtable += "</tr>";

	/* actual image */
	outtable += "<tr>";
	outtable += "<td>image min: <span class=\"sfnr_imgmin\">"+ sfnrdata.act_minval +"</span></td>";
	outtable += "<td style=\"text-align: right;\">image max: <span class=\"sfnr_imgmax\">" + sfnrdata.act_maxval + "</span></td>";
	outtable += "<td colspan=\"3\"></td>";
	outtable += "</tr>";

	outtable += "<tr>";
	outtable += "<td colspan=\"2\"><img id=\"sfnr_" + k + "\" class=\"scalable sfnr_img\" src=\""+ sfnrdata.data + "\"></td>";
	outtable += "<td></td>";
	outtable += "<td colspan=\"2\"><img src=\"" + datapath + jsondata[fileind]['mask_data']  + "\"></td>";
	outtable += "</tr>";
	outtable += "</tbody></table>";

	/* insert the table */
	$("ul.means li:last").append(outtable);
	/* add a link inside the navigation */
	$("#navigation #means_home #means_runs").append( "<li>" + k + "</li>" )
    }




    /* wait until everything is loaded */
    $(window).load(function() {
	/* scale only if able */
	if (!useSimple){
	    /* when all the image LIs have been inserted, trigger the scale */
	    if ( $("ul.means li").size() == localshortnames.length ){
		do { $("#errors").append("<div style=\"display:none;\">scaled means</div>") } while ( !ScaleImages("mean") )
                do { $("#errors").append("<div style=\"display:none;\">scaled sfnr</div>") } while ( !ScaleImages("sfnr") )
		do { $("#errors").append("<div style=\"display:none;\">scaled stddev</div>") } while ( !ScaleImages("stddev") )
	    }
	}

	/* add the additional stats links */
	/*var thisarr=["volmean_z_grand","volmean_z_indiv","cmassx_disp_grand","cmassx_disp_indiv",
	  "cmassx_z_grand","cmassx_z_indiv","cmassy","cmassy_disp_grand","cmassy_disp_indiv","cmassy_z_grand",
	  "cmassy_z_indiv","cmassz","cmassz_disp_grand","cmassz_disp_indiv","cmassz_z_grand","cmassz_z_indiv",
	  "masked_volmean","masked_volmean_z_grand","masked_volmean_z_indiv","masked_cmassx","masked_cmassx_disp_grand",
	  "masked_cmassx_disp_indiv","masked_cmassx_z_grand","masked_cmassx_z_indiv","masked_cmassy","masked_cmassy_disp_grand",
	  "masked_cmassy_disp_indiv","masked_cmassy_z_grand","masked_cmassy_z_indiv","masked_cmassz","masked_cmassz_disp_grand",
	  "masked_cmassz_disp_indiv","masked_cmassz_z_grand","masked_cmassz_z_indiv","masked_outlier_count","masked_outlier_percent",
	  "masked_fwhmx","masked_fwhmy","masked_fwhmz"]*/

	for (var i = 0; i < qakeys.length; i++) {
	    var k = qakeys[i];
	    var toadd = true;
	    $("#navigation #qaItems_home #indiv_stats li").each(function(){
                if ( $(this).text() == k ){
                    toadd = false
		}
            });
            
	    if ( toadd ){
		/* insert the new link */
		$("#navigation #qaItems_home #indiv_stats").append("<li>"+ k +"</li>")	
	    }
	}

	/* clean up some vars */
	//delete slicevardata,jsondata,jsoncbar,voldata;
        slicevardata = null;
        jsondata = null;
        jsoncbar = null;
        voldata = null;

    });




    /* function for scaling images */        
    //        $(".Scale").click(function() {
    //            var thisstat = $(this).attr("id");

    function ScaleImages(thisstat){
	if ( !useSimple ){
            
	    var mins = [];
	    var maxs = [];

	    $("ul.means table.means span.disp_" + thisstat + "_imgmin").each(function() {
                mins.push( parseFloat($(this).text()) );
            })

                $("ul.means table.means span.disp_" + thisstat + "_imgmax").each(function() {
		    maxs.push( parseFloat($(this).text()) );
		})

                    var overallmin = Math.min.apply(null,mins)
            var overallmax = Math.max.apply(null,maxs)             
            var rangeall = overallmax - overallmin;
            
	    /* cycle through each of the means and scale individually */
	    $("ul.means table.means img." + thisstat +"_img").each(function() {
                var thismin = parseFloat( $(this).closest("tr").parent().find("span.disp_" + thisstat + "_imgmin").text() )
		var thismax = parseFloat( $(this).closest("tr").parent().find("span.disp_" + thisstat + "_imgmax").text() )

		var range = thismax - thismin
		var offset = 255*( thismin - overallmin )/rangeall
		var scale = range / rangeall
		
		var imgObj = document.getElementById($(this).attr("id"));
                var canvas = document.createElement('canvas');
                var canvasContext = canvas.getContext('2d');
		
                var imgW = imgObj.width;
                var imgH = imgObj.height;
                canvas.width = imgW;
                canvas.height = imgH;
                canvasContext.drawImage(imgObj, 0, 0);

                var imageData = canvasContext.getImageData(0, 0, imgW, imgH);
                var d = imageData.data;

                var gammacut = 0.018;
                var gammacut2 = gammacut*4.5;
                var normoffset = (thismin - overallmin) / rangeall;
                if ( /(sfnr|mean)/.test(thisstat) ) {
                    for (var i=0; i<d.length; i+=4) {
                        d[i]   = offset + (d[i] * scale);
                        d[i+1] = offset + (d[i+1] * scale);
                        d[i+2] = offset + (d[i+2] * scale);
                    }
                } else {
                    for (var i=0; i<d.length; i+=4) {
                        var red  =d[i];
                        var green=d[i+1];
                        var blue =d[i+2];

			// un-gamma correct
			red = red / 255;
			green = green / 255;
			blue = blue / 255;

			red = ( (red<=gammacut2)*(red/4.5) ) + ( (red>gammacut2) * Math.pow(((red+0.099)/1.099),(1/0.45)) );
			green = ( (green<=gammacut2)*(green/4.5) ) + ( (green>gammacut2) * Math.pow(((green+0.099)/1.099),(1/0.45)) );
			blue = ( (blue<=gammacut2)*(blue/4.5) ) + ( (blue>gammacut2) * Math.pow(((blue+0.099)/1.099),(1/0.45)) );

                        red = red * 255;
                        green = green * 255;
                        blue = blue * 255;

                        var oldpos = 0;
                        if (red < 25.5) {
			    oldpos = red / 255;
                        } else if (red < 255) {
			    oldpos = 0.1 + ((red - 25.5) / 229.5) * 0.3;
                        } else if (green < 255) {
			    oldpos = 0.4 + (green / 255) * 0.3;
                        } else {
			    oldpos = 0.7 + (blue / 255) * 0.3;
                        }
                        var newpos = normoffset + oldpos * scale;
                        if (newpos < 0.1) {
			    red = newpos * 255;
			    green = red;
			    blue = red;
                        } else if (newpos < 0.4) {
			    var bracketpos = (newpos - 0.1) / 0.3;
			    red = 255 * (0.1 + (0.9 * bracketpos));
			    green = 255 * (0.1 - (0.1 * bracketpos));
			    blue = 255 * (0.1 - (0.1 * bracketpos));
                        } else if (newpos < 0.7) {
			    var bracketpos = (newpos - 0.4) / 0.3;
			    red = 255;
			    green = 255 * bracketpos;
			    blue = 0;
                        } else {
			    var bracketpos = (newpos - 0.7) / 0.3;
			    red = 255;
			    green = 255;
			    blue = 255 * bracketpos;
                        }
			// re-gamma correct
			red = red / 255;
			green = green / 255;
			blue = blue / 255;
			red = ( (red<=gammacut)*(red*4.5) )+( (red>gammacut)*(1.099*Math.pow(red,0.45)-0.099) );
			green = ( (green<=gammacut)*(green*4.5) )+( (green>gammacut)*(1.099*(Math.pow(green,0.45))-0.099) );
			blue = ( (blue<=gammacut)*(blue*4.5) )+( (blue>gammacut)*( 1.099*( Math.pow(blue,0.45) )-0.099) );
                        red = red * 255;
                        green = green * 255;
                        blue = blue * 255;
                        d[i] = red;
                        d[i+1] = green;
                        d[i+2] = blue;
                    }
                } 

		
                canvasContext.putImageData(imageData, 0, 0, 0, 0, imageData.width, imageData.height);
                imgObj.src = canvas.toDataURL()
	    });


            /* replace all the colorbar values, these are visible */
	    $("ul.means table.means span." + thisstat + "_cbarmin").each(function(){
		$(this).text(overallmin)
	    })

		$("ul.means table.means span." + thisstat + "_cbarmax").each(function(){
		    $(this).text(overallmax)
		})

		    /* replace hidden min/max vals */
		    $("ul.means table.means span.disp_" + thisstat + "_imgmin").each(function() {
			$(this).text(overallmin)
		    })

			$("ul.means table.means span.disp_" + thisstat + "_imgmax").each(function() {
			    $(this).text(overallmax)
			})



			    } else {
				alert("Update your browser to something modern, then we can do that");
			    }

	return true;
    };



    /* function for showing/hiding tables, use this method for dynamic content */        
    $("ul.qaItems").on("click","div.hideButton",function(e) {
        $(this).next().fadeToggle("fast");
        if ( $(this).text() == "show data" ) {
            $(this).text("hide data");
        } else if ( $(this).text() == "hide data" ) {
            $(this).text("show data");
        }

    });

    /* fades if checkbox selected */
    $("body").on("click","input",function(e) {
        if ( /\w_(LI)$/.test($(this).parent().next("li").attr("id")) ){  
            $(this).parent().next("li").toggle("fast");
        } else if ( $(this).parent().is("td") ) {
            var thisid = $(this).val();
            $("#" + thisid).toggle("fast")
	} else {
            $(this).nextUntil("hr","ul").toggle("fast");
        }
    });

    /* navigation functions */
    $("#navigation").on("click","li",function(event){
        var anchor;
        if ( /\w+\_(home)/.test( $(this).attr("id") ) ) {
            anchor = $(this).attr("id")            
	    anchor = anchor.replace(/(\_home)/gi,"")
	    anchor = "." + anchor;
        } else {
            if (/(means|slicevar)/.test( $(this).parent().attr("id") )) {
                anchor = $(this).parent().attr("id")
		anchor = "#" + anchor.replace(/(runs)/gi,$(this).text())
	    } else {
                anchor = $(this).text()
		/* if the requested LI doesn't exist, build the stats */
		if ( $("#" + anchor + "_LI").length == 0 ){
                    
		    var thisdata = load_mystat(anchor,runs2process,localshortnames);
		    //$("#errors").append("<pre>" + dump(thisdata) + "</pre>");
		    InsertGraph(anchor,runs2process,thisdata, localshortnames);
		}

                anchor = "#" + anchor + "_LI"
	    }
        }   


        /* scroll the page there */
        $("html, body").animate({
	    scrollTop: $(anchor).offset().top
	}, 1);

        event.preventDefault();
        event.stopPropagation();
    });


    /* hover the tooltip
       $(document).on("mouseenter","label",function(event){
       $(this).next(".description").show();
       });

       $(document).on("mouseleave","label",function(event){
       $(this).next(".description").hide();
       });
    */

    /* tooltip */
    $(document).on("click",".help",function(event){
        if ( $(this).parents("ul").attr("class") == "qaItems" ) {
            var stat = $(this).prev().text()
	    stat = stat.replace(/(\:|\s+)/gi,"")          
	    $(this).next(".description").html("<b>" + qahash[stat].plottitle + "</b>: " + qahash[stat].description + "<div class=\"close\">close</div>").toggle();
        } else {
            $(this).next(".description").toggle();
        }
    });

    $(document).on("click",".close",function(event){
        $(this).parent(".description").hide();
    });   



    /* //for some reason this doesn't work on dynamic elements 
       $("ul.qaItems label").on({
       mouseenter:function(event){
       $(this).next(".description").show();
       },
       mouseleave:function(event){
       $(this).next(".description").hide();
       }
       });
    */

    $("#testButton").click(function(e){
        var thisid="volmean";
        var canvas = document.getElementById(thisid);
	
        var thisscatter = canvas.__object__;

        //alert(thisscatter.data.length)          

        //$("#errors").append("<pre>"+ dump(thisscatter.Get('chart.key')) +"</pre>")

        var chartkey = thisscatter.Get('chart.key');
        var newdata = []
	var newkey  = []
	for ( var k in thisscatter.data ){
	    if ( k > 2 ){
		newdata.push(thisscatter.data[k])
		newkey.push(chartkey[k])
	    }
	}

        var newscatter = thisscatter
	newscatter.data = newdata
	newscatter.Set('chart.key',newkey)
	newscatter.Draw();

    });


    /* close button */
    $("div.description div.close").on("click",function(e){
        $(this).parent().toggle();
    })


    /* reload button behavior */
    $(".summary #overall_summary td #reload").on("click",function(e){
	var theseruns = []
	$("input[name='inc_runs\\[\\]']:checked").each(function(e){
	    theseruns.push(parseInt($(this).val()));
	});                        
        var newvoldata = [];
        var newshortnames = [];
        var newruns = [];
        for (var runind = 0; runind < theseruns.length; runind++) {
            newvoldata.push([]);
            newruns.push(runind);
            newshortnames.push(localshortnames[theseruns[runind]]);
        } 
        for ( var i = 0; i < preloaded_stats.length; i++ ) {
            k = preloaded_stats[i];
	    var thisdata = load_mystat(k,theseruns,localshortnames);

	    var missingdata = false;
	    for (var runind = 0; runind < theseruns.length; runind++) {
		if (thisdata[theseruns[runind]][k].length == 0) {
		    missingdata = true;
		    break;
	        }
	    }
	    if (missingdata) {
                continue;
            }

	    for (var runind = 0; runind < theseruns.length; runind++) {
                newvoldata[runind][k] = thisdata[theseruns[runind]][k];
            }
	}

        for ( var i = 0; i < preloaded_stats.length; i++ ) {
            var k = preloaded_stats[i];
//$("#errors").append("<pre>" + dump(thisdata) + "</pre>");
	    ShowGraph(k, newruns, newvoldata, newshortnames);
        }

	/* set the runs2process array to the new value */
	runs2process = theseruns;

	return true;
    });

});
