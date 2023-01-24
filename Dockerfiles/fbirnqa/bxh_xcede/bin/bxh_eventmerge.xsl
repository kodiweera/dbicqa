<?xml version="1.0" encoding="utf-8"?>

<!-- This stylesheet goes through each event in the input XML events file,
     and applies an XPath query (parameter "query").  It then searches a
     second document (parameter "mergesource") for events which give the
     same result when applying XPath mergequery (parameter "mergequery"
     or, if empty, value of parameter "query").  If there is a match, then
     the children of the event from the second document (optionally selected
     by parameter "grabquery") are merged into the event from the input
     document and written as output.  Any input events that don't have a
     match in the second document are output without change.
     The default path for events is namespace-ignorant //events/event ,
     but this can be changed in either the base document or merge document
     with the params "eventpath" and "mergeeventpath".
     -->
     
<xsl:stylesheet
  xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
  xmlns:dyn="http://exslt.org/dynamic"
  exclude-result-prefixes="xsl dyn"
  version="1.0">

  <xsl:output
    method="xml"
    indent="yes"
    omit-xml-declaration="no"
    />

  <xsl:param name="inputquery"/> <!-- REQUIRED -->
  <xsl:param name="mergedoc"/> <!-- REQUIRED -->
  <!-- the following params have default values, and are optional -->
  <xsl:param name="mergequery">
    <xsl:value-of select="$inputquery" />
  </xsl:param>
  <xsl:param name="inputeventpath">//*[local-name()="events"]/*[local-name()="event"]</xsl:param>
  <xsl:param name="mergeeventpath">//*[local-name()="events"]/*[local-name()="event"]</xsl:param>
  <xsl:param name="grabquery" select="'*'" />
  <xsl:param name="grabincludeset" select="''" />
  <xsl:param name="grabexcludeset" select="''" />

  <xsl:variable name="apos">'</xsl:variable>

  <xsl:variable name="eventset" select="dyn:evaluate($inputeventpath)" />
  <xsl:variable name="eventcount" select="count($eventset)" />

  <xsl:variable name="mergeeventsetevalstr" select="concat('document(', $apos, $mergedoc, $apos, ',/)', $mergeeventpath)"/>
  <xsl:variable name="mergeeventset" select="dyn:evaluate($mergeeventsetevalstr)" />


  <!-- generic identity transform -->
  <xsl:template match="@*|node()">
    <xsl:copy>
      <xsl:apply-templates select="@*|node()" />
    </xsl:copy>
  </xsl:template>

  <xsl:template match="/">
    <xsl:call-template name="main" />
  </xsl:template>

  <xsl:template name="main">
    <xsl:copy>
      <xsl:for-each select="@*|node()">
        <xsl:choose>
          <xsl:when test="count(.|$eventset) = $eventcount">
            <!-- current node is in the event set -->
            <xsl:call-template name="do_event" />
          </xsl:when>
          <xsl:otherwise>
            <xsl:call-template name="main" />
          </xsl:otherwise>
        </xsl:choose>
      </xsl:for-each>
    </xsl:copy>
  </xsl:template>

  <xsl:template name="do_event">
    <xsl:variable name="inresult" select="dyn:evaluate($inputquery)"/>
    <xsl:copy>
      <xsl:apply-templates select="@*|*|comment()|processing-instruction()|text()[count(following-sibling::node()) != 0]"/>
      <xsl:if test="$inresult != ''">
	<xsl:variable name="spacing" select="text()[position() = last()-1]" />
        <xsl:for-each select="$mergeeventset">
          <xsl:variable name="mergeresult" select="dyn:evaluate($mergequery)"/>
          <xsl:if test="$inresult = $mergeresult">
            <xsl:for-each select="$spacing">
              <xsl:copy />
            </xsl:for-each>
            <xsl:for-each select="dyn:evaluate($grabquery)">
              <xsl:choose>
                <xsl:when test="$grabincludeset != ''">
                  <xsl:call-template name="copyelement_include">
                    <xsl:with-param name="includeset" select="dyn:evaluate($grabincludeset)" />
                  </xsl:call-template>
                </xsl:when>
                <xsl:when test="$grabexcludeset != ''">
                  <xsl:call-template name="copyelement_exclude">
                    <xsl:with-param name="excludeset" select="dyn:evaluate($grabexcludeset)" />
                  </xsl:call-template>
                </xsl:when>
                <xsl:otherwise>
                  <xsl:call-template name="copyelement_exclude">
                    <!-- send the empty node-set as the excludeset to copy
                         everything -->
                    <xsl:with-param name="excludeset" select="/.." />
                  </xsl:call-template>
                </xsl:otherwise>
              </xsl:choose>
            </xsl:for-each>
          </xsl:if>
        </xsl:for-each>
      </xsl:if>
      <xsl:apply-templates select="text()[count(following-sibling::node()) = 0]"/>
    </xsl:copy>
  </xsl:template>

  <xsl:template name="copyelement_include">
    <xsl:param name="includeset" />
    <xsl:if test="count(.|$includeset) = count($includeset)">
      <xsl:copy>
	<xsl:for-each select="@*|node()">
          <xsl:call-template name="copyelement_include">
	    <xsl:with-param name="includeset" select="$includeset" />
	  </xsl:call-template>
        </xsl:for-each>
      </xsl:copy>
    </xsl:if>
  </xsl:template>
  <xsl:template name="copyelement_exclude">
    <xsl:param name="excludeset" />
    <xsl:if test="count(.|$excludeset) != count($excludeset)">
      <xsl:copy>
	<xsl:for-each select="@*|node()">
          <xsl:call-template name="copyelement_exclude">
	    <xsl:with-param name="excludeset" select="$excludeset" />
	  </xsl:call-template>
        </xsl:for-each>
      </xsl:copy>
    </xsl:if>
  </xsl:template>
</xsl:stylesheet>

<!--
     $Log: In-line log eliminated on transition to SVN; use svn log instead. $
     -->
