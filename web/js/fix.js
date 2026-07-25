function setCookie(cname, cvalue, exdays) {
    var d = new Date();
    d.setTime(d.getTime() + (exdays * 24 * 60 * 60 * 1000));
    var expires = "expires="+d.toUTCString();
    document.cookie = cname + "=" + cvalue + ";" + expires + ";path=/";
}

function getCookie(cname) {
    var name = cname + "=";
    var ca = document.cookie.split(';');
    for(var i = 0; i < ca.length; i++) {
        var c = ca[i];
        while (c.charAt(0) === ' ') {
            c = c.substring(1);
        }
        if (c.indexOf(name) === 0) {
            return c.substring(name.length, c.length);
        }
    }
    return "";
}

function showIoLog(animate) {
    //console.log('animate='+animate);
    if (animate==0) {
        $(".l-content .l-center, .l-content > .docker-shell").css("margin-right", 240);
        $(".to-top").css("right", 285);
        $(".to-shortcuts").css("right", 330);
        $(".right_sidebar").css("right", 0);
        //$(".io-log2").css("right", 0);
        //$("#myvesta_float").css("margin-right", 280);
    } else {
        $(".l-content .l-center, .l-content > .docker-shell").animate({"margin-right": 240});
        $(".to-top").animate({"right": 285});
        $(".to-shortcuts").animate({"right": 330});
        $(".right_sidebar").animate({"right": 0});
        //$(".io-log2").animate({"right": 0});
        //$("#myvesta_float").animate({"margin-right": 280});
    }

    /*
    $.ajax({url: "/list/log/", success: function(result){
            $( ".io-log div" ).remove();
            $($(result).find('.l-center.units')).insertAfter(".io-log h2");
            $( ".io-log div" ).removeClass();
    }});
    */
}

function hideIoLog(animate){
    //console.log('animate='+animate);
    if (animate==0) {
        $(".l-content .l-center, .l-content > .docker-shell").css("margin-right", 40);
        $(".to-top").css("right", 85);
        $(".to-shortcuts").css("right", 130);
        $(".right_sidebar").css("right", -200);
        //$("#myvesta_float").css("margin-right", 100);
    } else {
        $(".l-content .l-center, .l-content > .docker-shell").animate({"margin-right": 40});
        $(".to-top").animate({"right": 85});
        $(".to-shortcuts").animate({"right": 130});
        $(".right_sidebar").animate({"right": -200});
        //$("#myvesta_float").animate({"margin-right": 100});
    }
}

function checkCookie() {
    iolog = getCookie("iolog");
    //console.log('cookie: "'+iolog+'"');
    if (iolog === '1') {
        return 1;
    }
    if (iolog === '0') {
        return 0;
    }
    if (iolog == '') {
        //console.log('cookie is empty');
        return '';
    }
}

// function getRandomInt(max) {
//   return Math.floor(Math.random() * max);
// }
// var randomnumber=getRandomInt(100000000);
var iohtml = '<div class="io-box clearfix">\n' +
    '      </div>';

$(document).ready(function(){
    //var sys_height=$(".io-log").height();
    //$(".io-log2").css("top", sys_height+50);
    /*
    setTimeout(function() {
        iolog = getCookie("iolog");
        if (iolog === '0') {
            //setCookie("iolog", 0, 365);
            hideIoLog(0);
            return 0;
        }
    }, 1);
    */

    //if (GLOBAL.CURRENT_USER_FINAL == 'admin') $(".body-user .l-content > .l-center.units").first().prepend( iohtml );

    $(".io-log").on("click", function() {
        var showlog=checkCookie();
        //console.log('cookie = "'+iolog+'"');
        if (showlog===1 || showlog=='') {
            //console.log('cookie is active or empty, calling hidelog()');
            setCookie("iolog", 0, 365);
            hideIoLog(1);
        }
        if (showlog===0) {
            //console.log('cookie is inactive, calling showlog()');
            setCookie("iolog", 1, 365);
            showIoLog(1);
        }

    });
});
