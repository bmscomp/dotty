package dotty.tools
package dotc
package core

import Contexts.*
import Decorators.*
import Flags.*
import Names.*
import Symbols.*
import Types.*
import Denotations.SingleDenotation

/** Utility for collecting accessible members from a type.
 *  This is shared between completion (IDE) and error suggestions (DidYouMean).
 */
object MemberCollector:

  /** Configuration for member collection.
   *
   *  @param isType           If true, collect type members; otherwise term members
   *  @param isApplied        If true, also include classes (for constructor proxies)
   *  @param includePrivate   If true, include private members
   *  @param includeSynthetic If true, include synthetic members
   *  @param includeConstructors If true, include constructors
   *  @param checkAccessibility If true, filter by accessibility from the site
   */
  case class Config(
    isType: Boolean,
    isApplied: Boolean = false,
    includePrivate: Boolean = false,
    includeSynthetic: Boolean = false,
    includeConstructors: Boolean = false,
    checkAccessibility: Boolean = false,
    site: Type = NoType
  )

  /** Check if a symbol matches the requested kind (type vs term).
   *
   *  @param sym       The symbol to check
   *  @param isType    Whether we're looking for types
   *  @param isApplied Whether the member access is applied (followed by `(`)
   */
  def kindOK(sym: Symbol, isType: Boolean, isApplied: Boolean)(using Context): Boolean =
    if isType then sym.isType
    else sym.isTerm || isApplied && sym.isClass && !sym.is(ModuleClass)
    // Also count classes if followed by `(` since they have constructor proxies,
    // but these don't show up separately as members.
    // Note: One needs to be careful here not to complete symbols. For instance,
    // we run into trouble if we ask whether a symbol is a legal value.

  /** Collect members from a type as symbols.
   *
   *  This is the preferred method for error suggestions (DidYouMean) where
   *  we only need the symbol names for Levenshtein distance comparison.
   */
  def collectSymbols(tpe: Type, config: Config)(using Context): collection.Set[Symbol] =
    for
      bc <- tpe.widen.baseClasses.toSet
      sym <- bc.info.decls.filter(sym => includeSymbol(sym, config))
    yield sym

  /** Collect members from a type as denotations.
   *
   *  This is the preferred method for completions where we need full
   *  denotation information including type signatures.
   */
  def collectDenotations(tpe: Type, config: Config)(using Context): Seq[SingleDenotation] =
    val result = scala.collection.mutable.Buffer[SingleDenotation]()
    for bc <- tpe.widen.baseClasses do
      for sym <- bc.info.decls.toList.filter(includeSymbol(_, config)) do
        result ++= sym.denot.alternatives.collect {
          case denot: SingleDenotation => denot
        }
    result.toSeq

  /** Check if a symbol should be included based on the configuration. */
  private def includeSymbol(sym: Symbol, config: Config)(using Context): Boolean =
    kindOK(sym, config.isType, config.isApplied)
    && (config.includeConstructors || !sym.isConstructor)
    && (config.includeSynthetic || !sym.flagsUNSAFE.is(Synthetic))
    && (config.includePrivate || !sym.flagsUNSAFE.is(Private))
    && (config.site == NoType || !config.checkAccessibility || sym.isAccessibleFrom(config.site))

  /** Check if a denotation should be included for completion purposes.
   *  This is a simplified version that just checks core membership validity.
   *
   *  @param denot  The denotation to check
   *  @param isType Whether we're completing types
   *  @param site   The site from which accessibility is checked
   *  @param checkAccessibility Whether to filter by accessibility
   */
  def isValidMember(denot: SingleDenotation, isType: Boolean, site: Type, checkAccessibility: Boolean)(using Context): Boolean =
    val sym = denot.symbol
    sym.exists
    && !sym.isConstructor
    && !sym.flagsUNSAFE.is(Synthetic)
    && (!checkAccessibility || sym.isAccessibleFrom(site))
    && kindOK(sym, isType, isApplied = false)

end MemberCollector
