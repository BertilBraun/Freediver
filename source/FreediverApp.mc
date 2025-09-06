using Toybox.Application as App;
using Toybox.WatchUi as Ui;
using Toybox.System as Sys;
using Toybox.Activity as Activity;
using Toybox.Timer as Timer;
using Toybox.Math as Math;
using Toybox.FitContributor as Fit;
using Toybox.ActivityRecording as AR;
using Toybox.Graphics as GR;
using Toybox.Lang as Lang;

const G = 9.80665; // m/s^2
const RHO = 1025.0; // seawater density; change to 1000 for fresh
const SAMPLE_MS = 1000;

// Dive detection (simple + robust)
const START_THRESH_M = 0.5; // start dive when depth >= this
const END_THRESH_M = 0.5; // end dive when depth <= this
const END_HOLD_MS = 2000; // must stay <= END_THRESH for this long to end

const FIELD_ID_DEPTH = 0;
const FIELD_ID_UNDER = 1;
const FIELD_ID_MAXDEPTH = 2;
const FIELD_ID_LONGEST = 3;

class FreediverApp extends App.AppBase {
  var _session = null;

  var _depthRecField; // MESG_TYPE_RECORD (timeline)
  var _underRecField; // MESG_TYPE_RECORD (0/1 helper)

  var _maxDepthSessField; // MESG_TYPE_SESSION (summary)
  var _longestDiveSessField; // MESG_TYPE_SESSION (summary)

  function initialize() {
    App.AppBase.initialize();
  }
  function onStart(state) {
    // Create/start a recording session
    _session = AR.createSession({
      :name => "Freedive",
      :sport => Activity.SPORT_GENERIC,
      :subSport => Activity.SUB_SPORT_APNEA_DIVING,
    });

    // --- RECORD fields (timeline, once per second) -------------------------
    _depthRecField = _session.createField("Depth_m", FIELD_ID_DEPTH, Fit.DATA_TYPE_FLOAT, {
      :mesgType => Fit.MESG_TYPE_RECORD,
      :units => "m",
    });
    _underRecField = _session.createField("Underwater", FIELD_ID_UNDER, Fit.DATA_TYPE_UINT8, {
      :mesgType => Fit.MESG_TYPE_RECORD,
      :units => "",
    });

    // --- SESSION fields (single values written at end) ---------------------
    _maxDepthSessField = _session.createField("MaxDepth_m", FIELD_ID_MAXDEPTH, Fit.DATA_TYPE_FLOAT, {
      :mesgType => Fit.MESG_TYPE_SESSION,
      :units => "m",
    });
    _longestDiveSessField = _session.createField("LongestDive_s", FIELD_ID_LONGEST, Fit.DATA_TYPE_UINT32, {
      :mesgType => Fit.MESG_TYPE_SESSION,
      :units => "s",
    });

    _session.start(); // begin writing a FIT activity file
  }

  function onStop(state) {
    if (_session != null && _session.isRecording()) {
      _session.stop();
      _session.save();
      _session = null;
    }
  }

  function getInitialView() {
    var view = new FreediverView();
    view._depthRecField = _depthRecField;
    view._underRecField = _underRecField;
    view._maxDepthSessField = _maxDepthSessField;
    view._longestDiveSessField = _longestDiveSessField;
    return [view];
  }
}

class FreediverView extends Ui.View {
  var _timer;
  var _p0 = null; // surface pressure (Pa)
  var _depth = 0.0;
  var _maxDepth = 0.0;
  var _lastDepth = 0.0; // if depth is > 1m and the last depth is < 1m, then it's a new dive
  var _lastDiveDepth = 0.0;

  var _sessionStartMs = 0;

  // Dive state
  var _diving = false;
  var _diveStartMs = 0;
  var _diveEndCandidateMs = null;
  var _longestDive_s = 0;

  // ActivityRecording session + FIT fields
  var _depthRecField; // MESG_TYPE_RECORD (timeline)
  var _underRecField; // MESG_TYPE_RECORD (0/1 helper)

  var _maxDepthSessField; // MESG_TYPE_SESSION (summary)
  var _longestDiveSessField; // MESG_TYPE_SESSION (summary)

  function initialize() {
    Ui.View.initialize();
  }

  function onShow() {
    _sessionStartMs = Sys.getTimer();

    // Tick loop
    _timer = new Timer.Timer();
    _timer.start(method(:_tick), SAMPLE_MS, true);
  }

  function onHide() {
    if (_timer) {
      _timer.stop();
    }

    // Close any in-progress dive/block bookkeeping
    if (_diving) {
      _updateLongestDive();
    }
  }

  function _updateLongestDive() {
    var now = Sys.getTimer();
    var dur_s = ((now - _diveStartMs) / 1000).toNumber();
    if (dur_s > _longestDive_s) {
      _longestDive_s = dur_s;
      if (_longestDiveSessField != null) {
        _longestDiveSessField.setData(_longestDive_s);
      }
    }
  }

  function onKey(evt) {
    // Long BACK = re-zero surface pressure and clear stats (handy between sessions)
    if (evt.getKey() == Ui.KEY_RESET && evt.getType() == Ui.CLICK_TYPE_HOLD) {
      _p0 = null;
      _maxDepth = 0;
      _diving = false;
      _diveEndCandidateMs = null;
      _longestDive_s = 0;
      _lastDepth = 0.0;
      _lastDiveDepth = 0.0;
      _sessionStartMs = 0;
      return true;
    }
    return false;
  }

  function _tick() as Void {
    var info = Activity.getActivityInfo();
    var p = null;
    try {
      p = info.rawAmbientPressure;
    } catch (e) {}
    if (p == null) {
      try {
        p = info.ambientPressure;
      } catch (e) {}
    }
    if (p == null) {
      Ui.requestUpdate();
      return;
    }

    if (_p0 == null) {
      _p0 = p;
    } // capture surface reference

    // Depth calculation (m)
    var d = (p - _p0) / (RHO * G);
    if (d < 0) {
      d = 0;
    }
    _depth = _depth == null ? d : _depth * 0.6 + d * 0.4; // gentle smoothing

    if (_depth > _maxDepth) {
      _maxDepth = _depth;
      if (_maxDepthSessField != null) {
        _maxDepthSessField.setData(_maxDepth);
      }
    }
    if (_depth > START_THRESH_M && _lastDepth < START_THRESH_M) {
      _lastDiveDepth = _depth; // start of dive
    }
    _lastDepth = _depth;
    if (_depth > _lastDiveDepth) {
      _lastDiveDepth = _depth; // continuously update the last dive depth
    }

    var now = Sys.getTimer();

    // --- Dive detection with hysteresis + end-hold
    if (!_diving && _depth >= START_THRESH_M) {
      _diving = true;
      _diveStartMs = now;
      _diveEndCandidateMs = null;
    } else if (_diving) {
      if (_depth <= END_THRESH_M) {
        if (_diveEndCandidateMs == null) {
          _diveEndCandidateMs = now;
        } else if (now - _diveEndCandidateMs >= END_HOLD_MS) {
          // End the dive
          _diving = false;
          _updateLongestDive();
          _diveEndCandidateMs = null;
        }
      } else {
        _diveEndCandidateMs = null;
      }
    }

    // --- Record a FIT sample each tick (timeline)
    // --- Write timeline values (next record message) ---
    if (_depthRecField != null) {
      _depthRecField.setData(_depth);
    }
    if (_underRecField != null) {
      _underRecField.setData(_depth >= START_THRESH_M ? 1 : 0);
    }

    Ui.requestUpdate();
  }

  function onUpdate(dc) {
    dc.clear();
    dc.setColor(GR.COLOR_WHITE, GR.COLOR_BLACK);

    var x = dc.getWidth() / 2;
    var y = 24;

    dc.drawText(x, y, GR.FONT_LARGE, "Current: " + _fmtDepth(_depth), GR.TEXT_JUSTIFY_CENTER);

    // Stats
    y += 64;
    dc.drawText(x, y, GR.FONT_SMALL, "Longest: " + _fmtSec(_longestDive_s), GR.TEXT_JUSTIFY_CENTER);
    y += 24;
    dc.drawText(x, y, GR.FONT_SMALL, "Max: " + _fmtDepth(_maxDepth), GR.TEXT_JUSTIFY_CENTER);
    y += 24;
    dc.drawText(x, y, GR.FONT_SMALL, "Last: " + _fmtDepth(_lastDiveDepth), GR.TEXT_JUSTIFY_CENTER);
    y += 32;
    var dur_s = ((Sys.getTimer() - _sessionStartMs) / 1000).toNumber();
    dc.drawText(x, y, GR.FONT_SMALL, "Total: " + _fmtSec(dur_s), GR.TEXT_JUSTIFY_CENTER);
  }

  function _fmtDepth(d) {
    return d.format("%.1f") + " m";
  }

  function _fmtSec(s) {
    var m = (s / 60).toNumber();
    var ss = (s % 60).toNumber();
    return m.format("%.2d") + ":" + ss.format("%.2d") + " s";
  }
}
